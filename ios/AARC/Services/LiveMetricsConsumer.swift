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
    /// Stashed by PhoneSession when it sees prepareWorkout (watch-initiated)
    /// or by RunOrchestrator when starting from the phone, so the Live
    /// Activity can label the run "Treadmill" / "Outdoor" correctly.
    /// Defaults to outdoor when unknown.
    var pendingRunType: RunType = .outdoor
    var pendingPersonalityId: String = "roast_coach"

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
        // Director runs FIRST so its predictions (next-milestone ETA,
        // protect window) are fresh when ScriptEngine fires and
        // ContextualCoach decides whether there's room for banter.
        RunDirector.shared.processTick(metrics)
        // Forward to the script engine so generated lines fire at the
        // right moments. No-op when the engine isn't active.
        ScriptEngine.shared.processTick(metrics)
        // ContextualCoach evaluates the same tick for reactive triggers
        // (HR spike, pace drop/surge, quiet stretch). It shares
        // ScriptEngine's cooldown via tryInject, so no double-talk.
        ContextualCoach.shared.processTick(metrics)
        // Jessica runs as a background producer: this pump keeps one line
        // pre-generated + pre-rendered and releases it into a quiet gap.
        // Decoupled from Ricky's cadence so she never races him.
        Conversation.shared.tick(metrics)
        // Snapshot into the per-100m live chart store. No-op if no
        // new bucket has been crossed.
        LiveRunChartStore.shared.ingest(metrics)
        // Emit a "metrics" telemetry event for the cloud dashboard's
        // performance charts. RunEventLog throttles this internally to
        // ~one row per 100m bucket OR ~10s — NOT one per 1Hz tick. Speed
        // is derived from pace (LiveMetrics carries no speed field):
        // m/s = 1000 / (sec/km).
        let speedMps: Double? = (metrics.currentPaceSecPerKm).flatMap { p in
            p > 0 ? 1000 / p : nil
        }
        RunEventLog.shared.recordMetrics(
            distanceMeters: metrics.distanceMeters,
            paceSecPerKm: metrics.currentPaceSecPerKm,
            hr: metrics.currentHeartRate,
            speedMps: speedMps
        )
        // Live Activity (lock screen + Dynamic Island). Throttled
        // internally to ~1Hz.
        LiveActivityController.shared.update(
            from: metrics,
            plan: ScriptPreviewStore.shared.currentPlan
        )
    }

    func ingestStarted(runId: UUID, startedAt: Date) {
        // Dedupe: queued WC transports can replay workoutStarted (e.g.
        // a userInfo copy landing after the sendMessage copy). A repeat
        // of the current run must not reset the engines mid-run.
        if currentRunId == runId, isRunActive { return }

        // Anti-double-tracking: if the user already fell back to
        // phone-only and the watch starts LATE (delayed delivery of the
        // original command), end the watch's run instead of running two
        // trackers at once. The phone-only run is the user's explicit
        // choice; the late watch run is a ghost.
        if PhoneWorkoutSession.shared.isActive {
            PhoneSession.shared.sendStateEvent(.endWorkout)
            return
        }

        // Settle the orchestrator's pending handover (adoption: any
        // fresh started run counts, even with a different runId).
        RunOrchestrator.shared.confirmWatchStarted(runId: runId)

        self.currentRunId = runId
        self.startedAt = startedAt
        self.lastFinishedWorkoutUUID = nil

        // Open the per-run diagnostics log (events + voice archive).
        RunEventLog.shared.startRun(runId: runId)
        RunEventLog.shared.record(
            "run.start",
            "runType=\(pendingRunType.rawValue);isTest=\(RunOrchestrator.shared.isTestRun ? 1 : 0)")

        // Real-world surroundings for the coaches — outdoor runs only.
        // The desk simulator runs the SAME pipeline fed by a synthetic
        // route from RunSimulator, so location-grounded feedback can be
        // diagnosed without leaving the chair.
        if pendingRunType == .outdoor {
            if RunOrchestrator.shared.isSimulating {
                PlaceContext.shared.startSimulated()
            } else {
                PlaceContext.shared.start()
            }
        }

        // Hand the most-recently generated script to ScriptEngine so it
        // can begin firing lines on the upcoming live-metrics ticks.
        // The plan (distance / time / open) lives in ScriptPreviewStore
        // and was the basis for the script's structure.
        // Wipe the previous run's chart so the new run starts clean.
        LiveRunChartStore.shared.reset()

        if let script = ScriptPreviewStore.shared.latest {
            ScriptEngine.shared.start(
                script: script,
                plan: ScriptPreviewStore.shared.currentPlan
            )
        }
        ContextualCoach.shared.start(runType: pendingRunType)
        RunDirector.shared.start(plan: ScriptPreviewStore.shared.currentPlan)
        LiveActivityController.shared.start(
            runId: runId,
            personalityId: pendingPersonalityId,
            runType: pendingRunType,
            plan: ScriptPreviewStore.shared.currentPlan,
            startedAt: startedAt
        )
    }

    func ingestPaused() {
        latest = latest?.with(state: .paused)
    }

    func ingestResumed() {
        latest = latest?.with(state: .running)
    }

    /// `workoutUUID` is nil for TEST / SIMULATED runs that intentionally
    /// wrote nothing to Apple Health — those persist a RunRecord straight
    /// from the live metrics instead of reading HealthKit back.
    func ingestEnded(workoutUUID: UUID?) {
        self.lastFinishedWorkoutUUID = workoutUUID
        latest = latest?.with(state: .ended)

        // Snapshot everything the post-run summary needs WHILE it's still
        // live (chart samples, route + POIs, hearted lines) and kick off
        // the closing roast — before we tear the engines down below.
        RunSummaryStore.shared.capture()

        // Wind down the script engine — the "finish" trigger should
        // already have fired during a normal run. If the user ended
        // early, any unspoken lines just go quiet.
        ScriptEngine.shared.stop()
        ContextualCoach.shared.stop()
        Conversation.shared.stop()
        RunDirector.shared.stop()
        PlaceContext.shared.stop()
        LiveActivityController.shared.end()

        // Seal + upload the per-run diagnostics (events JSONL, pinned
        // voice audio). Fire-and-forget with retries inside.
        RunEventLog.shared.record("run.end", "workout=\(workoutUUID?.uuidString.prefix(8) ?? "test/sim")")
        RunEventLog.shared.endRun()

        guard let workoutUUID else {
            // Test / simulated run — no HealthKit workout. Persist a record
            // straight from the live metrics so it still shows in History
            // (flagged test) and replays its diagnostics.
            persistTestRunFromLive()
            return
        }
        // Kick off persistence in the background. HK may take a few
        // seconds to propagate the workout from watch to iPhone, so the
        // task retries with backoff.
        Task { await persistRun(workoutUUID: workoutUUID) }
    }

    /// Persist a RunRecord for a test/sim run (no HK workout) from the last
    /// live metrics. Flagged `isTestData`, no `healthKitWorkoutUUID`.
    private func persistTestRunFromLive() {
        let context = PersistenceStore.shared.container.mainContext
        let id = currentRunId ?? UUID()
        if let existing = try? context.fetch(FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.id == id })), !existing.isEmpty { return }
        let dist = latest?.distanceMeters ?? 0
        let dur = latest?.elapsed ?? 0
        // Persist the chart series + trail so History can render this test run
        // (no HealthKit workout to read back from).
        var series = StoredRunSeries()
        for s in LiveRunChartStore.shared.samples {
            if let h = s.heartRate, h > 0 { series.hr.append(.init(t: s.recordedAt, v: h)) }
            if let p = s.paceSecPerKm, p > 0 { series.pace.append(.init(t: s.recordedAt, v: p)) }
        }
        series.trail = PlaceContext.shared.trail.map {
            .init(lat: $0.coord.latitude, lon: $0.coord.longitude, kmh: $0.kmh, hr: $0.hr)
        }
        let record = RunRecord(
            id: id,
            startedAt: startedAt ?? .now,
            endedAt: .now,
            personality: pendingPersonalityId,
            isTestData: true,
            healthKitWorkoutUUID: nil,
            runTypeRaw: pendingRunType.rawValue,
            cachedDistanceMeters: dist,
            cachedDurationSeconds: dur,
            cachedAvgPaceSecPerKm: dist > 0 ? dur / (dist / 1000) : 0,
            cachedEnergyKcal: 0,
            seriesBlob: try? JSONEncoder().encode(series)
        )
        context.insert(record)
        try? context.save()
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
        // Test either from the HK workout metadata OR the start-screen toggle.
        let isTest = HealthKitReader.shared.isTestData(workout) || RunOrchestrator.shared.isTestRun
        let aarcId = HealthKitReader.shared.aarcRunId(workout) ?? currentRunId ?? UUID()
        let duration = workout.duration
        let avgPace = (distance > 0) ? duration / (distance / 1000) : 0

        let existing = try? context.fetch(
            FetchDescriptor<RunRecord>(
                predicate: #Predicate { $0.healthKitWorkoutUUID == workoutUUID }
            )
        )

        let savedRecord: RunRecord
        if let record = existing?.first {
            record.endedAt = workout.endDate
            record.cachedDistanceMeters = distance
            record.cachedDurationSeconds = duration
            record.cachedAvgPaceSecPerKm = avgPace
            record.cachedEnergyKcal = energy
            record.runTypeRaw = runType.rawValue
            record.isTestData = isTest
            savedRecord = record
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
            savedRecord = record
        }

        try? context.save()

        // Push the latest snapshot to the App Group so the home-screen
        // widget can show this run. Splits (pace + HR) derived from
        // the in-run chart store BEFORE it resets for the next run.
        // We send BOTH per-km (for legacy widget code paths) AND the
        // fine per-100m series (for the smooth chart line).
        let splits = LastRunSnapshotStore.splitsFromLiveStore()
        let fine = LastRunSnapshotStore.fineSeriesFromLiveStore()
        LastRunSnapshotStore.write(
            from: savedRecord,
            paceSplits: splits.pace,
            hrSplits: splits.hr,
            paceFine: fine.pace,
            hrFine: fine.hr
        )
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
            isTestData: false,
            healthKitWorkoutUUID: workoutUUID,
            runTypeRaw: latest?.lastSplit == nil ? "outdoor" : "outdoor",
            cachedDistanceMeters: latest?.distanceMeters ?? 0,
            cachedDurationSeconds: latest?.elapsed ?? 0,
            cachedAvgPaceSecPerKm: latest?.avgPaceSecPerKm ?? 0,
            cachedEnergyKcal: latest?.energyKcal ?? 0
        )
        context.insert(record)
        try? context.save()

        // Push a best-effort snapshot off the stub so the home-screen
        // widget shows something while HK syncs in the background.
        let splits = LastRunSnapshotStore.splitsFromLiveStore()
        let fine = LastRunSnapshotStore.fineSeriesFromLiveStore()
        LastRunSnapshotStore.write(
            from: record,
            paceSplits: splits.pace,
            hrSplits: splits.hr,
            paceFine: fine.pace,
            hrFine: fine.hr
        )
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
            cadenceStepsPerMinute: cadenceStepsPerMinute,
            lastSplit: lastSplit,
            state: newState
        )
    }
}
