import Testing
import Foundation
import AARCKit
@testable import AARC

/// Harness B — iOS run-lifecycle invariants (Swift Testing, host-app, headless,
/// network-free). Same philosophy as the feedback sim (Harness A): drive the
/// REAL singletons through their real guards and assert the invariant, instead
/// of flaky screen-driving XCUITest.
///
/// Targets the UI/lifecycle bugs surfaced on real runs. First up: the PHANTOM
/// RUN — a new run kicking off on the post-run summary page. The fix was
/// `RunOrchestrator.canStartNewRun` (false while a summary is presenting or a
/// run is active) gating every start path. These tests lock that invariant so
/// it can never silently regress.
@MainActor
@Suite("Run lifecycle invariants")
struct RunLifecycleHarness {

    /// Put the lifecycle singletons into a known idle state (tests share a
    /// process, so don't trust ambient state).
    private func resetToIdle() {
        let c = LiveMetricsConsumer.shared
        c.latest = nil
        c.currentRunId = nil
        // RunSummaryStore.summary is private(set) and nil at process start; a
        // network-free test never calls capture(), so it stays nil here.
    }

    private func metrics(_ state: WorkoutState) -> LiveMetrics {
        LiveMetrics(elapsed: 120, distanceMeters: 400,
                    currentPaceSecPerKm: 360, avgPaceSecPerKm: 360,
                    currentHeartRate: 150, energyKcal: 30,
                    cadenceStepsPerMinute: 160, lastSplit: nil, state: state)
    }
    private func runningMetrics() -> LiveMetrics { metrics(.running) }

    @Test("idle → a new run is allowed")
    func idleAllowsStart() {
        resetToIdle()
        #expect(LiveMetricsConsumer.shared.isRunActive == false)
        #expect(RunOrchestrator.shared.canStartNewRun == true)
    }

    @Test("a run already active BLOCKS a new run (phantom-run guard)")
    func activeRunBlocksStart() {
        resetToIdle()
        LiveMetricsConsumer.shared.latest = runningMetrics()
        #expect(LiveMetricsConsumer.shared.isRunActive == true)
        #expect(RunOrchestrator.shared.canStartNewRun == false)
    }

    /// The real defense, end-to-end + network-free: with a run active,
    /// `startPhoneOnly` must early-out on the `canStartNewRun` guard BEFORE any
    /// generation/network — leaving phase untouched and minting no new run.
    @Test("startPhoneOnly is a no-op while a run is active")
    func startPhoneOnlyNoOpsWhenActive() async {
        resetToIdle()
        LiveMetricsConsumer.shared.latest = runningMetrics()
        let activeRunId = UUID()
        LiveMetricsConsumer.shared.currentRunId = activeRunId

        #expect(RunOrchestrator.shared.phase == .idle)
        await RunOrchestrator.shared.startPhoneOnly(runType: .treadmill)

        // Guard held: no generation kicked off, no run identity replaced.
        #expect(RunOrchestrator.shared.phase == .idle)
        #expect(LiveMetricsConsumer.shared.currentRunId == activeRunId)
    }

    /// A paused run also counts as active — a stray start mid-pause must not
    /// spawn a second tracker.
    @Test("a paused run also blocks a new run")
    func pausedRunBlocksStart() {
        resetToIdle()
        LiveMetricsConsumer.shared.latest = metrics(.paused)
        #expect(LiveMetricsConsumer.shared.isRunActive == true)
        #expect(RunOrchestrator.shared.canStartNewRun == false)
    }
}
