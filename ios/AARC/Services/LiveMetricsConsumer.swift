import Foundation
import Observation
import SwiftData
import HealthKit
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
        // Forward to the script engine so generated lines fire at the
        // right moments. No-op when the engine isn't active.
        ScriptEngine.shared.processTick(metrics)
    }

    func ingestStarted(runId: UUID, startedAt: Date) {
        self.currentRunId = runId
        self.startedAt = startedAt
        self.lastFinishedWorkoutUUID = nil

        // Hand the most-recently generated script to ScriptEngine so it
        // can begin firing lines on the upcoming live-metrics ticks.
        // §1.7 will replace this "use whatever's in ScriptPreviewStore"
        // path with a proper Ready-to-run flow on RunHomeView; for now
        // the contract is: generate a script in Settings → Script
        // Preview, then start the run.
        if let script = ScriptPreviewStore.shared.latest {
            let plannedMeters = ScriptPreviewStore.shared.distanceKm * 1000
            ScriptEngine.shared.start(
                script: script,
                plannedDistanceMeters: plannedMeters
            )
        }
    }

    func ingestPaused() {
        latest = latest?.with(state: .paused)
    }

    func ingestResumed() {
        latest = latest?.with(state: .running)
    }

    func ingestEnded(workoutUUID: UUID) {
        self.lastFinishedWorkoutUUID = workoutUUID
        latest = latest?.with(state: .ended)

        // Wind down the script engine — the "finish" trigger should
        // already have fired during a normal run. If the user ended
        // early, any unspoken lines just go quiet.
        ScriptEngine.shared.stop()

        // Kick off persistence in the background. HK may take a few
        // seconds to propagate the workout from watch to iPhone, so the
        // task retries with backoff.
        Task { await persistRun(workoutUUID: workoutUUID) }
    }

    /// Fetch the workout from HealthKit and write a `RunRecord` row.
    /// Idempotent: if a record with the same HK UUID already exists,
    /// it is updated rather than duplicated.
    private func persistRun(workoutUUID: UUID) async {
        guard let workout = try? await HealthKitReader.shared.fetchWorkoutWithRetry(uuid: workoutUUID) else {
            // We can still create a stub record so the run isn't lost;
            // the cached fields will be 0 until HK syncs and the user
            // pulls to refresh (a future affordance).
            createStubRecord(workoutUUID: workoutUUID)
            return
        }

        let context = PersistenceStore.shared.container.mainContext

        // Pull denormalised fields out of HK.
        let distance = HealthKitReader.shared.distanceMeters(workout)
        let energy = HealthKitReader.shared.energyKcal(workout)
        let runType = HealthKitReader.shared.runType(workout)
        let isTest = HealthKitReader.shared.isTestData(workout)
        let aarcId = HealthKitReader.shared.aarcRunId(workout) ?? currentRunId ?? UUID()
        let duration = workout.duration
        let avgPace = (distance > 0) ? duration / (distance / 1000) : 0

        let existing = try? context.fetch(
            FetchDescriptor<RunRecord>(
                predicate: #Predicate { $0.healthKitWorkoutUUID == workoutUUID }
            )
        )

        if let record = existing?.first {
            record.endedAt = workout.endDate
            record.cachedDistanceMeters = distance
            record.cachedDurationSeconds = duration
            record.cachedAvgPaceSecPerKm = avgPace
            record.cachedEnergyKcal = energy
            record.runTypeRaw = runType.rawValue
            record.isTestData = isTest
        } else {
            let record = RunRecord(
                id: aarcId,
                startedAt: workout.startDate,
                endedAt: workout.endDate,
                personality: "roast_coach",  // §1.5 will source this properly
                isTestData: isTest,
                healthKitWorkoutUUID: workoutUUID,
                runTypeRaw: runType.rawValue,
                cachedDistanceMeters: distance,
                cachedDurationSeconds: duration,
                cachedAvgPaceSecPerKm: avgPace,
                cachedEnergyKcal: energy
            )
            context.insert(record)
        }

        try? context.save()
    }

    private func createStubRecord(workoutUUID: UUID) {
        let context = PersistenceStore.shared.container.mainContext
        let id = currentRunId ?? UUID()
        let existing = try? context.fetch(
            FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        )
        guard existing?.isEmpty ?? true else { return }
        let record = RunRecord(
            id: id,
            startedAt: startedAt ?? .now,
            endedAt: .now,
            personality: "roast_coach",
            isTestData: true,
            healthKitWorkoutUUID: workoutUUID,
            runTypeRaw: latest?.lastSplit == nil ? "outdoor" : "outdoor",
            cachedDistanceMeters: latest?.distanceMeters ?? 0,
            cachedDurationSeconds: latest?.elapsed ?? 0,
            cachedAvgPaceSecPerKm: latest?.avgPaceSecPerKm ?? 0,
            cachedEnergyKcal: latest?.energyKcal ?? 0
        )
        context.insert(record)
        try? context.save()
    }
}

private extension LiveMetrics {
    func with(state newState: WorkoutState) -> LiveMetrics {
        LiveMetrics(
            elapsed: elapsed,
            distanceMeters: distanceMeters,
            currentPaceSecPerKm: currentPaceSecPerKm,
            avgPaceSecPerKm: avgPaceSecPerKm,
            currentHeartRate: currentHeartRate,
            energyKcal: energyKcal,
            lastSplit: lastSplit,
            state: newState
        )
    }
}
