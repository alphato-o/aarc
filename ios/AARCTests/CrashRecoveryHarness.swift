import Testing
import Foundation
@testable import AARC

/// Harness B — crash recovery. The Qingdao run (55D745CB, 2026-08-09) was lost
/// because the phone crashed generating the closing speech and nothing on disk
/// recorded that a run had ever been open. The workout was safe in HealthKit
/// the whole time; the app just had no reason to go looking.
///
/// These lock the breadcrumb's behaviour. The HealthKit half can't run in a
/// unit test (no store, no workouts), so what's pinned here is the part that
/// decides WHETHER we go looking at all — which is the part that failed.
@MainActor
@Suite("Unfinished-run breadcrumb", .serialized)
struct CrashRecoveryHarness {

    private func reset() { UnfinishedRunStore.clear() }

    @Test("no marker when no run has started")
    func cleanSlate() {
        reset()
        #expect(UnfinishedRunStore.pending == nil)
    }

    @Test("a started run leaves a marker that survives being re-read")
    func markPersists() {
        reset()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        UnfinishedRunStore.mark(runId: id, startedAt: start, runTypeRaw: "treadmill",
                                personalityId: "roast_coach", isTest: false)
        let m = UnfinishedRunStore.pending
        #expect(m?.runId == id)
        #expect(m?.startedAt == start)
        #expect(m?.runTypeRaw == "treadmill")
        #expect(m?.isTest == false)
        reset()
    }

    @Test("a clean finish clears the marker — a finished run is never resurrected")
    func cleanFinishClears() {
        reset()
        UnfinishedRunStore.mark(runId: UUID(), startedAt: .now, runTypeRaw: "treadmill",
                                personalityId: "roast_coach", isTest: false)
        #expect(UnfinishedRunStore.pending != nil)
        UnfinishedRunStore.clear()
        #expect(UnfinishedRunStore.pending == nil)
    }

    @Test("a new run supersedes an older orphaned marker")
    func newRunSupersedes() {
        reset()
        let old = UUID(), new = UUID()
        UnfinishedRunStore.mark(runId: old, startedAt: .now.addingTimeInterval(-9000),
                                runTypeRaw: "outdoor", personalityId: "roast_coach", isTest: false)
        UnfinishedRunStore.mark(runId: new, startedAt: .now, runTypeRaw: "treadmill",
                                personalityId: "jessica", isTest: false)
        #expect(UnfinishedRunStore.pending?.runId == new)
        reset()
    }

    @Test("touch() advances lastSeenAt only after its throttle window")
    func touchIsThrottled() {
        reset()
        UnfinishedRunStore.mark(runId: UUID(), startedAt: .now, runTypeRaw: "treadmill",
                                personalityId: "roast_coach", isTest: false)
        let first = UnfinishedRunStore.pending!.lastSeenAt
        UnfinishedRunStore.touch()   // immediately after: must be a no-op
        #expect(UnfinishedRunStore.pending?.lastSeenAt == first)
        reset()
    }

    /// The liveness stamp is what separates "a real run died" from "a mis-tap
    /// died", so it has to survive an encode/decode round trip intact.
    @Test("marker round-trips through storage without losing the liveness clock")
    func livenessSurvivesEncoding() {
        reset()
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        UnfinishedRunStore.mark(runId: UUID(), startedAt: start, runTypeRaw: "treadmill",
                                personalityId: "roast_coach", isTest: false)
        let m = UnfinishedRunStore.pending!
        #expect(m.lastSeenAt.timeIntervalSince(m.startedAt) > 0)
        reset()
    }
}

/// Harness B — treadmill calibration. The watch infers indoor distance from
/// wrist motion, so a strap that loosens or tightens changes the number. On
/// 31 Aug that produced a "negative split" the founder never ran: "that's like
/// hallucination, that's not actually true because the speed was actually
/// constant." These pin the correction maths.
@MainActor
@Suite("Treadmill calibration")
struct CalibrationHarness {

    private func run(distance: Double, duration: Double) -> RunRecord {
        RunRecord(id: UUID(), startedAt: .now, endedAt: .now, personality: "roast_coach",
                  isTestData: false, healthKitWorkoutUUID: nil, runTypeRaw: "treadmill",
                  cachedDistanceMeters: distance, cachedDurationSeconds: duration,
                  cachedAvgPaceSecPerKm: duration / (distance / 1000), cachedEnergyKcal: 0)
    }

    @Test("an uncalibrated run shows the watch's own numbers unchanged")
    func passthrough() {
        let r = run(distance: 11_150, duration: 3618)
        #expect(r.calibrationFactor == nil)
        #expect(r.displayDistanceMeters == 11_150)
        #expect(abs(r.displayAvgPaceSecPerKm - r.cachedAvgPaceSecPerKm) < 0.001)
    }

    @Test("calibrating replaces the DISPLAYED distance but never the raw reading")
    func keepsRaw() {
        let r = run(distance: 11_150, duration: 3618)
        r.calibratedDistanceMeters = 10_500
        #expect(r.displayDistanceMeters == 10_500)
        // The watch's number must survive so the correction stays visible AS a
        // correction, and so re-calibrating never compounds.
        #expect(r.cachedDistanceMeters == 11_150)
    }

    @Test("pace is recomputed against the corrected distance")
    func paceFollows() {
        let r = run(distance: 10_000, duration: 3600)   // 6:00/km by the watch
        r.calibratedDistanceMeters = 12_000             // he actually did 12km
        #expect(abs(r.displayAvgPaceSecPerKm - 300) < 0.001)   // 5:00/km
    }

    @Test("the factor reports which way the watch was wrong")
    func factorDirection() {
        let short = run(distance: 10_000, duration: 3600)
        short.calibratedDistanceMeters = 11_000
        #expect((short.calibrationFactor ?? 0) > 1)      // watch under-read

        let long = run(distance: 10_000, duration: 3600)
        long.calibratedDistanceMeters = 9_000
        #expect((long.calibrationFactor ?? 0) < 1)       // watch over-read
    }

    @Test("nonsense calibration can't produce a divide-by-zero or a fake pace")
    func guardsZero() {
        let r = run(distance: 10_000, duration: 3600)
        r.calibratedDistanceMeters = 0
        // 0 is not a usable correction: fall back rather than divide by it.
        #expect(r.calibrationFactor == nil)
        #expect(r.displayAvgPaceSecPerKm > 0)
    }
}
