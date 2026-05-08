import Foundation
import Observation
import AARCKit

/// iPhone-side sink for the watch's 1 Hz `LiveMetrics` stream. Holds the
/// latest snapshot, the current run identity, and a "is the watch
/// currently feeding us data" health indicator. SwiftUI views observe
/// this directly; in later phases the ScriptEngine will subscribe too.
@Observable
@MainActor
final class LiveMetricsConsumer {
    static let shared = LiveMetricsConsumer()

    /// Latest snapshot pushed by the watch. Resets to nil between runs.
    var latest: LiveMetrics?

    /// Run identity supplied by the watch's `workoutStarted` event.
    var currentRunId: UUID?
    var startedAt: Date?

    /// HK workout UUID supplied by `workoutEnded`.
    var lastFinishedWorkoutUUID: UUID?

    /// When the most recent live-metrics packet arrived. Used by the
    /// connection watchdog to detect a stale watch link.
    var lastUpdateAt: Date?

    /// True iff a workout is in progress according to the watch.
    var isRunActive: Bool {
        guard let latest else { return false }
        return latest.state == .running || latest.state == .paused
    }

    /// True if no live metrics have arrived for >10s while supposedly
    /// active. The UI surfaces this as a "watch reconnecting…" hint.
    var isWatchStale: Bool {
        guard isRunActive, let lastUpdateAt else { return false }
        return Date().timeIntervalSince(lastUpdateAt) > 10
    }

    func ingest(_ metrics: LiveMetrics) {
        self.latest = metrics
        self.lastUpdateAt = .now
    }

    func ingestStarted(runId: UUID, startedAt: Date) {
        self.currentRunId = runId
        self.startedAt = startedAt
        self.lastFinishedWorkoutUUID = nil
    }

    func ingestPaused() {
        if var m = latest {
            m = LiveMetrics(
                elapsed: m.elapsed,
                distanceMeters: m.distanceMeters,
                currentPaceSecPerKm: m.currentPaceSecPerKm,
                avgPaceSecPerKm: m.avgPaceSecPerKm,
                currentHeartRate: m.currentHeartRate,
                energyKcal: m.energyKcal,
                lastSplit: m.lastSplit,
                state: .paused
            )
            self.latest = m
        }
    }

    func ingestResumed() {
        if var m = latest {
            m = LiveMetrics(
                elapsed: m.elapsed,
                distanceMeters: m.distanceMeters,
                currentPaceSecPerKm: m.currentPaceSecPerKm,
                avgPaceSecPerKm: m.avgPaceSecPerKm,
                currentHeartRate: m.currentHeartRate,
                energyKcal: m.energyKcal,
                lastSplit: m.lastSplit,
                state: .running
            )
            self.latest = m
        }
    }

    func ingestEnded(workoutUUID: UUID) {
        self.lastFinishedWorkoutUUID = workoutUUID
        // Mark the latest snapshot as ended; UI uses this to wind down.
        if var m = latest {
            m = LiveMetrics(
                elapsed: m.elapsed,
                distanceMeters: m.distanceMeters,
                currentPaceSecPerKm: m.currentPaceSecPerKm,
                avgPaceSecPerKm: m.avgPaceSecPerKm,
                currentHeartRate: m.currentHeartRate,
                energyKcal: m.energyKcal,
                lastSplit: m.lastSplit,
                state: .ended
            )
            self.latest = m
        }
        // Run record persistence lands in §1.9 (post-run summary).
    }
}
