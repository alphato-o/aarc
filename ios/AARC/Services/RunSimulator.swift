import Foundation
import Observation
import AARCKit

/// Desk-test metrics source. When the start screen's test mode is
/// `.simulate`, this drives SYNTHETIC `LiveMetrics` into the exact same
/// pipeline a real run uses (`LiveMetricsConsumer.ingest`) — so the
/// director, ContextualCoach, Jessica producer, ScriptEngine milestones and
/// all the audio fire just as they would on the road, without the founder
/// leaving his chair. No GPS, no pedometer, no HealthKit.
///
/// The Control Room exposes live controls (pace, speed multiplier,
/// pause/stationary, HR/pace event injects, distance jump) so a whole run
/// can be exercised — including fast-forwarding to the painful back half to
/// hear how Jessica ramps.
@MainActor
@Observable
final class RunSimulator {
    static let shared = RunSimulator()

    private(set) var isActive = false

    // MARK: - Operator controls (read + written by the Control Room)

    /// Target pace. Distance accrues at 1000/pace m/s (× the multiplier).
    var paceSecPerKm: Double = 360          // 6:00 /km
    /// 1× = real time. Higher accelerates BOTH distance and the run clock so
    /// you reach milestones / the late-run Jessica ramp sooner. Audio still
    /// plays in real time (you can't speed up a voice line meaningfully).
    var speedMultiplier: Double = 1.0
    /// Paused = the clock and distance freeze (you're "standing still" — good
    /// for triggering the stationary roast).
    var paused = false

    // Synthetic HR model.
    var targetHeartRate: Double = 150

    // MARK: - Synthetic state

    private(set) var simElapsed: TimeInterval = 0
    private(set) var simDistance: Double = 0
    private var smoothedHR: Double = 110
    private var hrSpikeUntil: TimeInterval = 0
    private var surgeUntil: TimeInterval = 0
    private var stationaryUntil: TimeInterval = 0
    private var lastWall: Date?
    private var ticker: Timer?

    private init() {}

    // MARK: - Lifecycle

    func start(runType: RunType, runId: UUID, personalityId: String, plan: RunPlan) {
        simElapsed = 0
        simDistance = 0
        smoothedHR = 110
        hrSpikeUntil = 0; surgeUntil = 0; stationaryUntil = 0
        paused = false
        lastWall = nil
        isActive = true

        LiveMetricsConsumer.shared.pendingRunType = runType
        LiveMetricsConsumer.shared.pendingPersonalityId = personalityId
        LiveMetricsConsumer.shared.ingestStarted(runId: runId, startedAt: Date())

        ticker?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker = t
    }

    func end() {
        guard isActive else { return }
        isActive = false
        ticker?.invalidate(); ticker = nil
        lastWall = nil
        LiveMetricsConsumer.shared.ingestEnded(workoutUUID: nil)
    }

    // MARK: - Operator actions

    func injectHRSpike() { hrSpikeUntil = simElapsed + 25 }
    func injectPaceSurge() { surgeUntil = simElapsed + 20 }
    func injectStationary() { stationaryUntil = simElapsed + 30 }

    /// Fast-forward the run by `meters`, advancing the clock at the current
    /// pace too, so scrubbing to "5 km" lands you at the right time as well.
    func jump(meters: Double) {
        guard isActive, meters > 0 else { return }
        simDistance += meters
        let speed = 1000.0 / max(60, paceSecPerKm)
        simElapsed += meters / speed
        publish()
    }

    // MARK: - Tick

    private func tick() {
        guard isActive else { return }
        let now = Date()
        let dtReal = lastWall.map { now.timeIntervalSince($0) } ?? 1.0
        lastWall = now
        guard !paused else { publish(); return }

        let dt = dtReal * max(0.25, speedMultiplier)
        let stationary = simElapsed < stationaryUntil
        simElapsed += dt

        // Distance advances unless we're "standing still".
        let surging = simElapsed < surgeUntil
        let pace = surging ? paceSecPerKm * 0.78 : paceSecPerKm   // surge = faster
        if !stationary {
            simDistance += (1000.0 / max(60, pace)) * dt
        }

        // HR drifts toward target, jumps on a spike, eases when stationary.
        let hrTarget = stationary ? 95 : (simElapsed < hrSpikeUntil ? targetHeartRate + 35 : targetHeartRate)
        smoothedHR += (hrTarget - smoothedHR) * min(1, dt / 12)

        publish(stationaryNow: stationary, surging: surging)
    }

    private func publish(stationaryNow: Bool = false, surging: Bool = false) {
        let curPace: Double? = stationaryNow ? nil : (surging ? paceSecPerKm * 0.78 : paceSecPerKm)
        let avg = simDistance > 0 ? simElapsed / (simDistance / 1000) : 0
        let metrics = LiveMetrics(
            elapsed: simElapsed,
            distanceMeters: simDistance,
            currentPaceSecPerKm: curPace,
            avgPaceSecPerKm: avg,
            currentHeartRate: smoothedHR,
            energyKcal: simDistance * 0.06,
            cadenceStepsPerMinute: stationaryNow ? 0 : (160 + (surging ? 14 : 0)),
            lastSplit: nil,
            state: .running
        )
        LiveMetricsConsumer.shared.ingest(metrics)
    }
}
