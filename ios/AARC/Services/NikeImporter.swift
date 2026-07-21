import Foundation
import SwiftData
import CryptoKit
import CoreLocation
import AARCKit

/// One-time importer for the founder's Nike Run Club archive (247 runs,
/// 2015-2026), pulled from the Nike sport/v3 API and massaged offline into
/// `Resources/nrc-import.json`. Nike runs land as VIEW-ONLY history: no
/// coaching, no share card — an archive so all running data lives in one
/// place (founder ask 2026-07). Idempotent: a re-import never duplicates.
///
/// Each run becomes a `RunRecord` (source="nike") whose `seriesBlob` holds the
/// HR/pace series + GPS trail, so the existing `RunDetailView` renders its
/// map + charts with zero new rendering code. The same run is also pushed to
/// the cloud dashboard via the standard `/ingest-run` event stream, so both
/// surfaces show the full record.
@MainActor
enum NikeImporter {

    struct Progress { var done: Int; var total: Int; var imported: Int; var skipped: Int }

    // MARK: - Wire shape (matches the massage script's compact JSON)
    private struct NikeRun: Decodable {
        struct Pt: Decodable { let t: Double; let v: Double }
        struct TPt: Decodable { let lat: Double; let lon: Double; let kmh: Double?; let hr: Double? }
        let nikeId: String
        let startMs: Double
        let endMs: Double?
        let durationS: Double
        let runType: String
        let distanceM: Double
        let avgPaceSecPerKm: Double
        let calories: Double
        let name: String
        let app: String
        let city: String?
        let hr: [Pt]
        let pace: [Pt]
        let trail: [TPt]
    }

    /// Deterministic UUID from the Nike activity id (UUIDv5-style, SHA-256
    /// truncated) so the same Nike run always maps to the same RunRecord.id —
    /// the `@unique` id then makes re-import a no-op.
    static func stableId(_ nikeId: String) -> UUID {
        let digest = SHA256.hash(data: Data(("nike:" + nikeId).utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // version 5-ish
        b[8] = (b[8] & 0x3F) | 0x80   // variant
        let t = (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])
        return UUID(uuid: t)
    }

    static func bundledCount() -> Int {
        (try? loadBundle().count) ?? 0
    }

    private static func loadBundle() throws -> [NikeRun] {
        guard let url = Bundle.main.url(forResource: "nrc-import", withExtension: "json") else {
            throw NSError(domain: "NikeImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "nrc-import.json not bundled"])
        }
        return try JSONDecoder().decode([NikeRun].self, from: Data(contentsOf: url))
    }

    /// Run the import. Creates local RunRecords + (optionally) pushes each to
    /// the dashboard. `onProgress` is called on the main actor after each run.
    static func run(context: ModelContext, pushToDashboard: Bool = true,
                    onProgress: @escaping (Progress) -> Void) async {
        let runs: [NikeRun]
        do { runs = try loadBundle() } catch {
            RunEventLog.shared.record("nike.import.error", String(describing: error)); return
        }
        // Index existing Nike records by id so a re-import UPSERTS (updates
        // runType/city/series) rather than skipping — this is how an already-
        // imported archive picks up a classifier fix (the case-insensitive
        // location + GPS-fallback reclassification, build 170).
        let existing = (try? context.fetch(FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.source == "nike" }))) ?? []
        var byExt: [String: RunRecord] = [:]
        for r in existing { if let e = r.externalId { byExt[e] = r } }

        var p = Progress(done: 0, total: runs.count, imported: 0, skipped: 0)
        for nr in runs {
            defer { p.done += 1; onProgress(p) }

            let started = Date(timeIntervalSince1970: nr.startMs / 1000)
            let ended = nr.endMs.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? started.addingTimeInterval(nr.durationS)

            // Build the series blob. iOS RunMapView uses Apple MapKit, whose
            // tiles inside mainland China are GCJ-02 — convert the WGS-84 Nike
            // track to display space so it sits on the streets (no-op abroad).
            var series = StoredRunSeries()
            series.hr = nr.hr.map { .init(t: started.addingTimeInterval($0.t), v: $0.v) }
            series.pace = nr.pace.map { .init(t: started.addingTimeInterval($0.t), v: $0.v) }
            series.trail = nr.trail.map { tp in
                let wgs = CLLocationCoordinate2D(latitude: tp.lat, longitude: tp.lon)
                let disp = ChinaCoordinateTransform.isMainlandChina(wgs)
                    ? ChinaCoordinateTransform.displayCoordinate(wgs) : wgs
                return .init(lat: disp.latitude, lon: disp.longitude, kmh: tp.kmh, hr: tp.hr)
            }
            let blob = try? JSONEncoder().encode(series)

            let rec: RunRecord
            if let existing = byExt[nr.nikeId] {
                // UPDATE in place — refresh the fields the bundle can correct
                // (runType reclassification, city, series).
                existing.runTypeRaw = nr.runType
                existing.city = nr.city
                existing.importedTitle = nr.name
                existing.cachedDistanceMeters = nr.distanceM
                existing.cachedDurationSeconds = nr.durationS
                existing.cachedAvgPaceSecPerKm = nr.avgPaceSecPerKm
                existing.cachedEnergyKcal = nr.calories
                existing.seriesBlob = blob
                rec = existing
                p.skipped += 1
            } else {
                rec = RunRecord(
                    id: stableId(nr.nikeId),
                    startedAt: started,
                    endedAt: ended,
                    personality: "roast_coach",
                    isTestData: false,
                    healthKitWorkoutUUID: nil,
                    runTypeRaw: nr.runType,
                    source: "nike",
                    externalId: nr.nikeId,
                    importedTitle: nr.name,
                    city: nr.city,
                    cachedDistanceMeters: nr.distanceM,
                    cachedDurationSeconds: nr.durationS,
                    cachedAvgPaceSecPerKm: nr.avgPaceSecPerKm,
                    cachedEnergyKcal: nr.calories,
                    seriesBlob: blob
                )
                context.insert(rec)
                p.imported += 1
            }
            try? context.save()

            // Push to the dashboard via the standard event stream (WGS-84 gps
            // events for the map, metrics events for the charts). Re-ingesting
            // the same runId updates it, so upserts fix the dashboard too.
            if pushToDashboard {
                let lines = eventStream(nr)
                _ = await RunEventLog.uploadEventStream(runId: rec.id, jsonlLines: lines)
            }
        }
        RunEventLog.shared.record("nike.import.done", "imported \(p.imported), skipped \(p.skipped)")
    }

    // MARK: - Dashboard event stream (mirrors RunHistoryBackfill's wire shape)

    private static let wall: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func num(_ v: Double?) -> String {
        guard let v, v.isFinite, v > 0 else { return "" }
        return String(format: "%.1f", v)
    }
    private static func line(_ start: Date, _ t: Double, _ type: String, _ detail: String, _ data: [String: String]) -> String {
        let ev: [String: Any] = [
            "t": (t * 1000).rounded() / 1000,
            "wall": wall.string(from: start.addingTimeInterval(t)),
            "type": type, "detail": detail, "data": data,
        ]
        let d = try? JSONSerialization.data(withJSONObject: ev, options: [.sortedKeys, .withoutEscapingSlashes])
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func eventStream(_ nr: NikeRun) -> [String] {
        let start = Date(timeIntervalSince1970: nr.startMs / 1000)
        var lines: [String] = []
        lines.append(line(start, 0, "run.start", "runType=\(nr.runType)",
                          ["runId": stableId(nr.nikeId).uuidString, "runType": nr.runType,
                           "source": "nike", "name": nr.name]))
        // metrics: pace + hr sampled on the pace clock; distance interpolated.
        for pt in nr.pace {
            let hr = nearest(nr.hr, pt.t)
            lines.append(line(start, pt.t, "metrics", "",
                              ["p": num(pt.v), "hr": num(hr), "d": num(distanceAt(nr, pt.t))]))
        }
        // gps events (WGS-84, raw Nike coords) drive the dashboard map.
        for tp in nr.trail {
            // trail carries no absolute t; approximate along the run by index
            // is unnecessary — the dashboard map only needs the ordered points.
            lines.append(line(start, 0, "gps", "",
                              ["lat": String(format: "%.6f", tp.lat),
                               "lon": String(format: "%.6f", tp.lon),
                               "kmh": tp.kmh.map { String(format: "%.1f", $0) } ?? "",
                               "hr": tp.hr.map { String(Int($0)) } ?? ""]))
        }
        lines.append(line(start, nr.durationS, "run.end", "nike-import",
                          ["source": "nike", "samples": String(nr.pace.count)]))
        return lines
    }

    private static func nearest(_ pts: [NikeRun.Pt], _ t: Double) -> Double? {
        guard !pts.isEmpty else { return nil }
        var best = pts[0]; var bg = abs(pts[0].t - t)
        for p in pts { let g = abs(p.t - t); if g < bg { bg = g; best = p } }
        return bg < 20 ? best.v : nil
    }
    /// Distance (m) at offset t, from the cumulative avg pace (the compact
    /// bundle dropped the raw distance stream; avg pace × time is close enough
    /// for the dashboard's distance axis, and the KPI uses the exact total).
    private static func distanceAt(_ nr: NikeRun, _ t: Double) -> Double? {
        guard nr.durationS > 0 else { return nil }
        return nr.distanceM * (t / nr.durationS)
    }
}
