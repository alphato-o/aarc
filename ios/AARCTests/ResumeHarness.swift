import Testing
import Foundation
import AARCKit
@testable import AARC

/// Harness B — relaunch mid-run. Founder, 2026-10-14, after the 198 crash at
/// 9 km: "if this happens in mid-race day, I need to be able to re-launch
/// the AARC app and resume the run, because the watch is still emitting."
///
/// The watch keeps the HealthKit session; the phone has to re-key itself to
/// the SAME run the instant metrics arrive again. These pin the decision
/// logic (breadcrumb → resume), the idempotent end, and the log-append rule.
@MainActor
@Suite("Relaunch mid-run resume", .serialized)
struct ResumeHarness {

    private func resetToIdle() {
        let c = LiveMetricsConsumer.shared
        c.latest = nil
        c.currentRunId = nil
        UnfinishedRunStore.clear()
        // A summary left presenting blocks every later start (phantom guard).
        RunSummaryStore.shared.dismiss()
    }

    private func running(_ dist: Double) -> LiveMetrics {
        LiveMetrics(elapsed: 1100, distanceMeters: dist,
                    currentPaceSecPerKm: 350, avgPaceSecPerKm: 355,
                    currentHeartRate: 160, energyKcal: 220,
                    cadenceStepsPerMinute: 168, lastSplit: nil, state: .running)
    }

    @Test("metrics with no run but a fresh breadcrumb resume the SAME run")
    func freshMarkerResumes() {
        resetToIdle()
        let id = UUID()
        let start = Date.now.addingTimeInterval(-1100)
        UnfinishedRunStore.mark(runId: id, startedAt: start, runTypeRaw: "outdoor",
                                personalityId: "roast_coach", isTest: false)
        LiveMetricsConsumer.shared.ingest(running(3100))
        let c = LiveMetricsConsumer.shared
        #expect(c.currentRunId == id)
        #expect(c.isRunActive)
        #expect(c.resumedFromMarker)
        #expect(c.latest?.distanceMeters == 3100)
        c.endNow()
        resetToIdle()
    }

    @Test("a test-run breadcrumb never resumes a real tracker")
    func testMarkerDoesNotResume() {
        resetToIdle()
        UnfinishedRunStore.mark(runId: UUID(), startedAt: .now.addingTimeInterval(-600),
                                runTypeRaw: "treadmill", personalityId: "roast_coach", isTest: true)
        LiveMetricsConsumer.shared.ingest(running(800))
        #expect(LiveMetricsConsumer.shared.currentRunId == nil)
        #expect(!LiveMetricsConsumer.shared.resumedFromMarker)
        resetToIdle()
    }

    @Test("a breadcrumb older than six hours is recovery, not resume")
    func staleMarkerDoesNotResume() {
        let m = UnfinishedRunStore.Marker(runId: UUID(), startedAt: .now.addingTimeInterval(-9 * 3600),
                                          runTypeRaw: "outdoor", personalityId: "roast_coach",
                                          isTest: false, lastSeenAt: .now.addingTimeInterval(-7 * 3600))
        #expect(!LiveMetricsConsumer.markerIsResumable(m))
        let fresh = UnfinishedRunStore.Marker(runId: UUID(), startedAt: .now.addingTimeInterval(-3000),
                                              runTypeRaw: "outdoor", personalityId: "roast_coach",
                                              isTest: false, lastSeenAt: .now.addingTimeInterval(-120))
        #expect(LiveMetricsConsumer.markerIsResumable(fresh))
        // A test run he actually ran (mode .real) resumes; a desk sim never.
        let testRun = UnfinishedRunStore.Marker(runId: UUID(), startedAt: .now.addingTimeInterval(-900),
                                                runTypeRaw: "treadmill", personalityId: "roast_coach",
                                                isTest: true, lastSeenAt: .now.addingTimeInterval(-30))
        #expect(LiveMetricsConsumer.markerIsResumable(testRun, allowTest: true))
        #expect(!LiveMetricsConsumer.markerIsResumable(testRun, allowTest: false))
    }

    @Test("a resumed run keeps the engines alive and ends exactly once")
    func resumedRunEndsOnce() {
        resetToIdle()
        let id = UUID()
        UnfinishedRunStore.mark(runId: id, startedAt: .now.addingTimeInterval(-2000), runTypeRaw: "outdoor",
                                personalityId: "roast_coach", isTest: false)
        LiveMetricsConsumer.shared.ingest(running(5000))
        LiveMetricsConsumer.shared.ingest(running(5020))
        let c = LiveMetricsConsumer.shared
        #expect(c.currentRunId == id)
        #expect(ScriptEngine.shared.isActive)
        c.endNow()
        #expect(!c.isRunActive)
        // A second end (the WC workoutEnded landing after the mirror fallback)
        // must be a no-op, not a second teardown.
        c.ingestEnded(workoutUUID: nil)
        c.ingestEnded(workoutUUID: nil)
        #expect(!c.isRunActive)
        resetToIdle()
    }

    @Test("identity arriving after metrics adopts the run instead of ending it")
    func metricsBeforeIdentityAdopts() {
        resetToIdle()
        // No breadcrumb (or a non-resumable one): metrics land first and flip
        // us to running with no runId; the watch's identity follows.
        let c = LiveMetricsConsumer.shared
        c.ingest(running(2500))
        #expect(c.isRunActive)
        #expect(c.currentRunId == nil)
        let id = UUID()
        c.ingestStarted(runId: id, startedAt: .now.addingTimeInterval(-900))
        #expect(c.currentRunId == id)
        #expect(c.isRunActive)
        c.endNow()
        resetToIdle()
    }

    @Test("a script swapped in mid-run pre-marks everything already passed")
    func replaceScriptPreMarks() {
        let msgs: [ScriptMessage] = [1000.0, 2000.0, 3000.0, 4000.0].enumerated().map { i, d in
            ScriptMessage(id: "km\(i + 1)",
                          triggerSpec: TriggerSpec(type: .distance, atSeconds: nil, everySeconds: nil,
                                                   atMeters: d, everyMeters: nil,
                                                   remainingMeters: nil, remainingSeconds: nil),
                          text: "km \(i + 1)")
        }
        let script = GeneratedScript(scriptId: "t", model: "none", messages: msgs)
        let e = ScriptEngine.shared
        e.start(script: GeneratedScript(scriptId: "empty", model: "none", messages: []), plan: ScriptPreviewStore.shared.currentPlan)
        e.replaceScript(script, currentMetrics: running(3100))
        #expect(e.isFired("km1"))
        #expect(e.isFired("km3"))
        #expect(!e.isFired("km4"))
        e.stop()
    }
}
