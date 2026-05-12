@preconcurrency import ActivityKit
import Foundation
import Observation
import OSLog
import AARCKit

/// Owns the iPhone Live Activity that surfaces an in-progress run on
/// the lock screen + Dynamic Island. Driven by LiveMetricsConsumer:
///   ingestStarted → start(...)
///   ingest        → update(...) (throttled)
///   ingestEnded   → end(...)
///
/// Activities require iOS 16.1+. We guard with availability checks and
/// silently no-op on older OSes, so the rest of the app doesn't have
/// to care.
@Observable
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// Surface state for the Settings diagnostic block.
    private(set) var isActive: Bool = false
    private(set) var lastUpdateAt: Date?
    private(set) var lastError: String?

    /// Strong reference to the currently-running activity. Optional —
    /// nil when no run is in progress (or when ActivityKit is gated by
    /// the OS / user permissions).
    private var activity: Activity<LiveActivityAttributes>?

    /// Most recent state we pushed; lets us short-circuit no-op updates
    /// (e.g. when distance hasn't ticked).
    private var lastState: LiveActivityAttributes.ContentState?

    /// Throttle activity updates to ~1 Hz max. ActivityKit allows
    /// frequent updates, but each one is a budget hit; the lock screen
    /// UI doesn't redraw faster than the 1 Hz LiveMetrics stream anyway.
    private let minUpdateInterval: TimeInterval = 0.95

    private let log = Logger(subsystem: "club.aarun.AARC", category: "LiveActivity")

    func start(
        runId: UUID,
        personalityId: String,
        runType: RunType,
        plan: RunPlan,
        startedAt: Date
    ) {
        guard #available(iOS 16.2, *) else {
            log.info("LiveActivity: iOS < 16.2, skipping")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("LiveActivity: user has disabled activities in Settings")
            lastError = "Live Activities disabled in iOS Settings"
            return
        }
        // If one is already running (e.g. a previous run wasn't cleanly
        // ended), end it before starting a new one — only one per run.
        if activity != nil {
            log.info("LiveActivity: ending stale activity before starting new one")
            Task { @MainActor in
                await endInternal(deliverFinal: nil)
                await beginActivity(runId: runId, personalityId: personalityId, runType: runType, plan: plan, startedAt: startedAt)
            }
            return
        }
        Task { @MainActor in
            await beginActivity(runId: runId, personalityId: personalityId, runType: runType, plan: plan, startedAt: startedAt)
        }
    }

    func update(from metrics: LiveMetrics, plan: RunPlan) {
        guard #available(iOS 16.2, *) else { return }
        guard let activity else { return }

        if let lastUpdateAt,
           Date().timeIntervalSince(lastUpdateAt) < minUpdateInterval {
            return
        }

        let state = LiveActivityAttributes.ContentState(
            elapsedSeconds: metrics.elapsed,
            distanceMeters: metrics.distanceMeters,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            avgPaceSecPerKm: metrics.avgPaceSecPerKm,
            currentHR: metrics.currentHeartRate,
            targetDistanceMeters: plan.totalMeters,
            targetSeconds: plan.totalSeconds,
            isPaused: metrics.state == .paused
        )

        if state == lastState { return }
        lastState = state
        lastUpdateAt = .now

        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(15))
        let snapshot = activity
        Task.detached {
            await snapshot.update(content)
        }
    }

    func end() {
        guard #available(iOS 16.2, *) else { return }
        Task { @MainActor in
            // Send one final snapshot that lingers briefly on the lock
            // screen showing the closing distance, then dismiss.
            let final = lastState
            await endInternal(deliverFinal: final)
        }
    }

    // MARK: - Private

    @available(iOS 16.2, *)
    private func beginActivity(
        runId: UUID,
        personalityId: String,
        runType: RunType,
        plan: RunPlan,
        startedAt: Date
    ) async {
        let attributes = LiveActivityAttributes(
            runId: runId,
            personalityId: personalityId,
            runType: runType,
            planKind: plan.kind,
            startedAt: startedAt
        )
        let initialState = LiveActivityAttributes.ContentState(
            elapsedSeconds: 0,
            distanceMeters: 0,
            currentPaceSecPerKm: nil,
            avgPaceSecPerKm: 0,
            currentHR: nil,
            targetDistanceMeters: plan.totalMeters,
            targetSeconds: plan.totalSeconds,
            isPaused: false
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: .now.addingTimeInterval(15)),
                pushType: nil
            )
            lastState = initialState
            lastUpdateAt = .now
            isActive = true
            lastError = nil
            log.info("LiveActivity started for run \(runId.uuidString.prefix(8), privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("LiveActivity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @available(iOS 16.2, *)
    private func endInternal(deliverFinal final: LiveActivityAttributes.ContentState?) async {
        guard let activity else { return }
        let snapshot = activity
        self.activity = nil
        self.lastState = nil
        self.lastUpdateAt = nil
        self.isActive = false
        log.info("LiveActivity ended")

        await Task.detached {
            if let final {
                let content = ActivityContent(state: final, staleDate: nil)
                await snapshot.end(content, dismissalPolicy: .after(.now + 8))
            } else {
                await snapshot.end(nil, dismissalPolicy: .immediate)
            }
        }.value
    }
}
