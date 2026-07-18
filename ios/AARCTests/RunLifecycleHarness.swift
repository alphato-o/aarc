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

    /// A LiveMetrics with EXPLICIT hr/distance, for the frozen-stream tests.
    private func metricsHR(_ hr: Double?, dist: Double) -> LiveMetrics {
        LiveMetrics(elapsed: 120, distanceMeters: dist,
                    currentPaceSecPerKm: 360, avgPaceSecPerKm: 360,
                    currentHeartRate: hr, energyKcal: 30,
                    cadenceStepsPerMinute: 160, lastSplit: nil, state: .running)
    }

    @Test("a dead sensor stream (HR pinned + distance stuck 45s) is flagged frozen")
    func frozenStreamDetected() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        let t0 = Date()
        // Field case C9F4129B: HR bit-identical, distance parked, for minutes.
        // The first sample only PRIMES the probe; the 45s freeze window is
        // measured from the second identical sample, so drive a full minute.
        for s in stride(from: 0.0, through: 60.0, by: 10.0) {
            c.updateFrozenDetection(metricsHR(97.0, dist: 0), now: t0.addingTimeInterval(s))
        }
        #expect(c.watchDataFrozen == true)
        // Stream comes alive → flag clears immediately.
        c.updateFrozenDetection(metricsHR(101.0, dist: 0), now: t0.addingTimeInterval(60))
        #expect(c.watchDataFrozen == false)
    }

    @Test("a healthy stream (HR varying) is never flagged frozen")
    func healthyStreamNotFrozen() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        let t0 = Date()
        // Same stuck distance (runner mid-pause) but LIVE heart data — this is
        // a real human standing still, not a dead stream. Must NOT flag.
        for (i, hr) in [97.0, 98.0, 97.0, 99.0, 101.0, 100.0].enumerated() {
            c.updateFrozenDetection(metricsHR(hr, dist: 50), now: t0.addingTimeInterval(Double(i) * 10))
        }
        #expect(c.watchDataFrozen == false)
    }

    @Test("a dead metrics stream (>150s, .running) is salvage-ended (lost watch-End)")
    func lostWatchEndIsSalvaged() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        c.currentRunId = UUID()
        c.latest = runningMetrics()
        c.lastUpdateAt = Date().addingTimeInterval(-200)   // stream dead 200s
        #expect(c.endReconciliationCheck() == true)
        #expect(c.isRunActive == false)                     // run finalised
        // The salvage presents a summary (capture()); dismiss so the other
        // invariants' idle baseline (canStartNewRun == true) still holds.
        RunSummaryStore.shared.dismiss()
    }

    @Test("a live stream is never salvage-ended")
    func liveStreamNotSalvaged() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        c.currentRunId = UUID()
        c.latest = runningMetrics()
        c.lastUpdateAt = Date().addingTimeInterval(-20)     // fresh
        #expect(c.endReconciliationCheck() == false)
        #expect(c.isRunActive == true)
    }

    @Test("a paused run is never salvage-ended, however stale")
    func pausedRunNotSalvaged() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        c.currentRunId = UUID()
        c.latest = metrics(.paused)
        c.lastUpdateAt = Date().addingTimeInterval(-600)
        #expect(c.endReconciliationCheck() == false)
        #expect(c.isRunActive == true)
    }

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

    /// INSTANT STOP (the >3s freeze fix): `endNow()` must flip `isRunActive`
    /// false SYNCHRONOUSLY — the UI leaves the run screen immediately, the
    /// HealthKit/watch teardown happens async behind it. `endNow` is a sync
    /// func, so asserting right after the call proves the flip is synchronous.
    /// We leave `currentRunId` nil so `capture()` early-returns and fires NO
    /// closing-roast network call (the synchronous state flip is independent of
    /// the run id).
    @Test("endNow flips isRunActive false synchronously (instant stop)")
    func endNowIsSynchronous() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        c.latest = runningMetrics()
        c.currentRunId = nil                // capture() early-returns → no roast/network
        #expect(c.isRunActive == true)

        c.endNow()                          // synchronous

        #expect(c.isRunActive == false)     // already false by the next line = instant
    }

    @Test("endNow is a safe no-op when nothing is running")
    func endNowNoopWhenIdle() {
        resetToIdle()
        #expect(LiveMetricsConsumer.shared.isRunActive == false)
        LiveMetricsConsumer.shared.endNow()
        #expect(LiveMetricsConsumer.shared.isRunActive == false)
    }

    /// THE PHANTOM RUN (2026-06-21): a ghost watch session re-announced a run
    /// while the summary was up and the phone started a zero'd tracker. Cause:
    /// the WATCH-driven start paths (MirroringReceiver `.identity`, the WC start
    /// message) call `ingestStarted` directly, bypassing `canStartNewRun` — the
    /// phone-only sim + the earlier guard tests never exercised them. This
    /// reproduces it at the choke point: a stale start while a run is active
    /// must be REFUSED, not adopted. (Fails before the ingestStarted guard;
    /// passes after.)
    @Test("a stale watch/mirror start is refused while a run is active (phantom guard)")
    func phantomStartRefusedWhileActive() {
        resetToIdle()
        let c = LiveMetricsConsumer.shared
        let activeRun = UUID()
        c.currentRunId = activeRun
        c.latest = runningMetrics()                      // isRunActive → canStartNewRun false
        #expect(RunOrchestrator.shared.canStartNewRun == false)

        c.ingestStarted(runId: UUID(), startedAt: Date())  // ghost re-announces a DIFFERENT run

        #expect(c.currentRunId == activeRun)             // phantom NOT adopted
    }
}
