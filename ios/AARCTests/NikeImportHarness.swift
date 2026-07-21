import Testing
import Foundation
import SwiftData
import CoreLocation
import AARCKit
@testable import AARC

/// Harness for the Nike Run Club import: drives the real NikeImporter into an
/// in-memory store and asserts the massage invariants — the new, risky code.
/// Serialized + a single shared import (five parallel 247-run imports thrash
/// SwiftData). Network push is off, so this is offline + fast.
@MainActor
@Suite("Nike import invariants", .serialized)
struct NikeImportHarness {

    @Test("race detection counts only half + full marathons")
    func raceDetection() {
        #expect(RunAggregate.isRace(21_097))   // exact half
        #expect(RunAggregate.isRace(42_195))   // exact full
        #expect(RunAggregate.isRace(21_800))   // half + GPS drift
        #expect(RunAggregate.isRace(42_900))   // full + GPS drift
        #expect(!RunAggregate.isRace(10_000))  // 10k — not a race
        #expect(!RunAggregate.isRace(18_000))  // long training run — not a race
        #expect(!RunAggregate.isRace(30_000))  // between half and full — not a race
    }

    @Test("stable id maps each Nike run to exactly one record")
    func stableIds() {
        #expect(NikeImporter.stableId("abc-123") == NikeImporter.stableId("abc-123"))
        #expect(NikeImporter.stableId("abc-123") != NikeImporter.stableId("different"))
    }

    @Test("full archive imports, is idempotent, and massages every case correctly")
    func fullImport() async throws {
        let container = try ModelContainer(for: RunRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext

        // Bundle is reachable and substantial (247 in the shipped archive).
        #expect(NikeImporter.bundledCount() > 200)

        await NikeImporter.run(context: ctx, pushToDashboard: false) { _ in }
        let all = try ctx.fetch(FetchDescriptor<RunRecord>())

        // — count + tagging —
        #expect(all.count == NikeImporter.bundledCount())
        #expect(all.allSatisfy { $0.source == "nike" && $0.externalId != nil && !$0.isTestData })
        #expect(all.allSatisfy { $0.cachedDistanceMeters > 0 && $0.cachedDurationSeconds > 0 })
        #expect(all.allSatisfy { $0.importedTitle != nil })

        // — idempotency: a second run adds nothing —
        await NikeImporter.run(context: ctx, pushToDashboard: false) { _ in }
        #expect(try ctx.fetch(FetchDescriptor<RunRecord>()).count == all.count)

        // — decode every seriesBlob —
        let decoded: [(RunRecord, StoredRunSeries)] = all.compactMap { r in
            r.seriesBlob.flatMap { b in
                (try? JSONDecoder().decode(StoredRunSeries.self, from: b)).map { (r, $0) }
            }
        }
        #expect(decoded.count == all.count)   // no blob failed to decode

        // — outdoor runs: many carry a valid GPS trail —
        let outdoorWithTrail = decoded.filter { $0.0.runTypeRaw == "outdoor" && $0.1.trail.count > 10 }
        #expect(outdoorWithTrail.count > 20)
        let anyTrail = outdoorWithTrail.first!.1.trail
        #expect(anyTrail.allSatisfy { $0.lat.isFinite && $0.lon.isFinite && abs($0.lat) <= 90 && abs($0.lon) <= 180 })

        // — treadmill runs: no GPS, but charts survive —
        let tread = decoded.filter { $0.0.runTypeRaw == "treadmill" }
        #expect(!tread.isEmpty)
        #expect(tread.allSatisfy { $0.1.trail.isEmpty })
        #expect(tread.contains { !$0.1.hr.isEmpty || !$0.1.pace.isEmpty })

        // — a China trail is stored in display space (GCJ-02 shift applied) —
        var checkedChina = false
        for (_, s) in outdoorWithTrail {
            guard let p = s.trail.first else { continue }
            let coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
            guard ChinaCoordinateTransform.isMainlandChina(coord) else { continue }
            let backWgs = ChinaCoordinateTransform.wgsCoordinate(fromDisplay: coord)
            #expect(abs(backWgs.latitude - p.lat) + abs(backWgs.longitude - p.lon) > 0.0005)
            checkedChina = true
            break
        }
        #expect(checkedChina)   // the archive has Beijing runs; we verified one
    }
}
