import Foundation
import SwiftData
import os

/// Backfills the cloud dashboard with PAST runs so their performance
/// charts render.
///
/// The dashboard's charts are driven by "metrics" events in each run's
/// event stream (the shared time-series contract). Live runs emit those
/// going forward via `RunEventLog.recordMetrics`, but runs that finished
/// before that shipped have no metrics rows on the Worker. This type
/// walks SwiftData history, reconstructs a minimal event stream per run
/// from HealthKit (run.start → a series of metrics → run.end), and
/// uploads each via the SAME `/ingest-run` path the live uploader uses
/// (`RunEventLog.uploadEventStream`).
///
/// Idempotent + cheap on repeat: every successfully-uploaded run id is
/// recorded in UserDefaults (`aarc.backfill.doneRunIds`); `backfillAll()`
/// checks the done-set first and returns immediately when nothing is
/// outstanding. Resilient: one run failing (no HK workout, upload error)
/// never aborts the rest, and each upload gets the same retry budget as
/// the live uploader.
@MainActor
enum RunHistoryBackfill {
    private static let log = Logger(subsystem: "club.aarun.AARC", category: "RunHistoryBackfill")

    nonisolated static let doneRunIdsKey = "aarc.backfill.doneRunIds"

    /// ISO-8601 with fractional seconds — matches `RunEventLog`'s wall
    /// clock format so historical and live runs serialise identically.
    /// `nonisolated(unsafe)`: read-only after init and only ever touched
    /// from the sequential (one-run-at-a-time) detached backfill loop.
    nonisolated(unsafe) private static let wallFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Backfill every not-yet-synced run. Safe + cheap to call on every
    /// app launch: returns immediately when the done-set already covers
    /// all of history. Fire-and-forget; runs off the main actor for the
    /// HealthKit + network work.
    static func backfillAll(force: Bool = false) {
        guard RunEventLog.backfillUploadEnabled else {
            log.notice("backfill skipped — AARCDeviceToken not set")
            return
        }

        let context = PersistenceStore.shared.container.mainContext
        let descriptor = FetchDescriptor<RunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        let records: [RunRecord]
        do {
            records = try context.fetch(descriptor)
        } catch {
            log.error("backfill fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Snapshot the plain-old-data we need OFF the @Model objects now,
        // on the main actor, so the detached worker never touches
        // SwiftData across actor boundaries.
        let done: Set<String> = force ? [] : doneSet()
        let pending: [PendingRun] = records.compactMap { record in
            guard !record.isTestData else { return nil }
            guard let hkUUID = record.healthKitWorkoutUUID else { return nil }
            if !force && done.contains(record.id.uuidString) { return nil }
            return PendingRun(
                runId: record.id,
                startedAt: record.startedAt,
                endedAt: record.endedAt ?? record.startedAt,
                durationSeconds: record.cachedDurationSeconds,
                runTypeRaw: record.runTypeRaw,
                hkUUID: hkUUID
            )
        }

        guard !pending.isEmpty else {
            log.info("backfill: nothing to do (\(records.count, privacy: .public) run(s) already synced or ineligible)")
            return
        }
        log.info("backfill: \(pending.count, privacy: .public) run(s) to sync")

        Task.detached(priority: .utility) {
            for run in pending {
                if await backfillOne(run) {
                    markDone(run.runId)
                }
            }
        }
    }

    /// Plain snapshot of one run's fields, decoupled from the @Model so
    /// it can cross into a detached Task safely (Sendable).
    private struct PendingRun: Sendable {
        let runId: UUID
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Double
        let runTypeRaw: String
        let hkUUID: UUID
    }

    /// Build + upload one historical run's event stream. Returns true on
    /// a successful upload (so the caller marks it done). Never throws —
    /// a missing HK workout or upload failure just returns false and the
    /// run stays eligible for the next launch.
    nonisolated private static func backfillOne(_ run: PendingRun) async -> Bool {
        // The non-Sendable HKWorkout never crosses back here: existence
        // check + timeline build both run inside the HealthKitReader actor.
        guard await HealthKitReader.shared.workoutExists(uuid: run.hkUUID) else {
            uploadLog.info("backfill: HK workout unavailable for \(run.runId.uuidString, privacy: .public) — leaving pending")
            return false
        }

        let samples = (try? await HealthKitReader.shared.fetchMetricsTimeline(
            uuid: run.hkUUID,
            bucketSeconds: 30
        )) ?? []

        // Duration falls back to the workout span if the cached value is
        // missing/zero (older stub records).
        let duration = run.durationSeconds > 0
            ? run.durationSeconds
            : max(0, run.endedAt.timeIntervalSince(run.startedAt))

        var lines: [String] = []
        lines.append(eventLine(
            runStart: run.startedAt,
            t: 0,
            type: "run.start",
            detail: "runType=\(run.runTypeRaw)",
            data: ["runId": run.runId.uuidString, "runType": run.runTypeRaw, "source": "backfill"]
        ))
        for s in samples {
            // Keep metrics within the run window; clamp t into [0, duration].
            let t = min(max(0, s.t), duration > 0 ? duration : s.t)
            lines.append(eventLine(
                runStart: run.startedAt,
                t: t,
                type: "metrics",
                detail: "",
                data: [
                    "d": num(s.distanceMeters),
                    "p": num(s.paceSecPerKm),
                    "hr": num(s.hr),
                    "v": num(s.speedMps),
                ]
            ))
        }
        lines.append(eventLine(
            runStart: run.startedAt,
            t: duration,
            type: "run.end",
            detail: "backfill",
            data: ["source": "backfill", "samples": String(samples.count)]
        ))

        let ok = await RunEventLog.uploadEventStream(runId: run.runId, jsonlLines: lines)
        if ok {
            uploadLog.info("backfill: uploaded \(run.runId.uuidString, privacy: .public) (\(samples.count, privacy: .public) metrics)")
        } else {
            uploadLog.error("backfill: upload failed for \(run.runId.uuidString, privacy: .public) — leaving pending")
        }
        return ok
    }

    // MARK: - JSONL encoding (mirrors RunEventLog's wire shape)

    nonisolated private static let uploadLog = Logger(subsystem: "club.aarun.AARC", category: "RunHistoryBackfill.upload")

    /// Format a value the same way the live `recordMetrics` does:
    /// one decimal, empty string for nil / non-finite / non-positive.
    nonisolated private static func num(_ v: Double?) -> String {
        guard let v, v.isFinite, v > 0 else { return "" }
        return String(format: "%.1f", v)
    }

    /// Serialise one event to a JSONL line matching RunLogEvent's
    /// CodingKeys ({t, wall, type, detail, data}) with sorted keys so
    /// the Worker parses it identically to a live-uploaded run.
    nonisolated private static func eventLine(
        runStart: Date,
        t: Double,
        type: String,
        detail: String,
        data: [String: String]
    ) -> String {
        let event = RunLogEvent(
            t: (t * 1000).rounded() / 1000,
            wall: wallFormatter.string(from: runStart.addingTimeInterval(t)),
            type: type,
            detail: detail,
            data: data
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? encoder.encode(event), let s = String(data: d, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    // MARK: - Done-set bookkeeping (UserDefaults)

    nonisolated private static func doneSet() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: doneRunIdsKey) ?? [])
    }

    nonisolated private static func markDone(_ runId: UUID) {
        var list = UserDefaults.standard.stringArray(forKey: doneRunIdsKey) ?? []
        guard !list.contains(runId.uuidString) else { return }
        list.append(runId.uuidString)
        UserDefaults.standard.set(list, forKey: doneRunIdsKey)
    }

    /// Wipe the done-set so the next `backfillAll()` re-syncs everything.
    /// Dev/debug affordance.
    static func resetDoneSet() {
        UserDefaults.standard.removeObject(forKey: doneRunIdsKey)
    }
}
