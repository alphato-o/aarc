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
