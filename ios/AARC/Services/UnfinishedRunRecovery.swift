import Foundation
import SwiftData

/// Rescues a run the app was in the middle of when it died.
///
/// Companion to `UnfinishedRunStore`. That leaves the breadcrumb; this follows
/// it at launch: find the Apple Health workout the run produced and turn it
/// back into a `RunRecord`, so a crash costs the founder his coach lines but
/// never his run.
///
/// Why matching by TIME WINDOW and not just by AARC's own run id: on the run
/// that motivated this (Qingdao, 2026-08-09) the treadmill had a GymKit NFC
/// tap. The native Workout app opened a session, AARC opened another, and the
/// two raced — HealthKit only permits one. The surviving workout can therefore
/// be owned by the GYM EQUIPMENT, carrying no AARC metadata at all. Matching
/// on `aarcRunId` alone would miss exactly the case this exists for, so the id
/// is preferred when present and an overlapping running workout is accepted
/// otherwise.
@MainActor
enum UnfinishedRunRecovery {

    enum Outcome: Equatable {
        case nothingPending
        /// A marker existed but the run is already in the database — a normal
        /// finish that simply never got its marker cleared. Nothing to do.
        case alreadyRecorded
        /// Recovered a workout into history.
        case recovered(distanceMeters: Double, durationSeconds: Double)
        /// The run was real but Health has no workout for it — nothing to
        /// rebuild from. The marker is kept so a later sync can still find it.
        case noWorkoutFound
    }

    /// How long after the start we will still believe a workout belongs to
    /// this run. Long enough for an ultra, short enough not to adopt the next
    /// day's run.
    private static let maxRunHours: Double = 12
    /// Runs shorter than this were never real — a mis-tap, or a start that
    /// crashed instantly. Recovering them would junk up history.
    private static let minMeaningfulSeconds: Double = 120

    /// Late-adopt a HealthKit workout onto a stub row, filling in the workout
    /// UUID (which is what unlocks the chart and the route) plus the
    /// authoritative distance, duration and energy.
    private static func heal(_ record: RunRecord, marker: UnfinishedRunStore.Marker,
                             existing: [RunRecord], context: ModelContext) async {
        let knownHK = Set(existing.compactMap { $0.healthKitWorkoutUUID })
        let window = marker.startedAt.addingTimeInterval(-300)...marker.startedAt
            .addingTimeInterval(maxRunHours * 3600)
        let candidates = await HealthKitReader.shared.recentRunningWorkouts()
            .filter { !$0.isTest && !knownHK.contains($0.uuid) && window.contains($0.start) }
        guard let w = candidates.first(where: { $0.aarcRunId == marker.runId })
                ?? candidates.min(by: {
                    abs($0.start.timeIntervalSince(marker.startedAt))
                        < abs($1.start.timeIntervalSince(marker.startedAt))
                }) else { return }
        record.healthKitWorkoutUUID = w.uuid
        record.endedAt = w.end
        // Only overwrite headline numbers when Health actually has them; a
        // zero from Health must never wipe a real number the live path caught.
        if w.distanceMeters > 0 { record.cachedDistanceMeters = w.distanceMeters }
        if w.durationSeconds > 0 { record.cachedDurationSeconds = w.durationSeconds }
        if w.energyKcal > 0 { record.cachedEnergyKcal = w.energyKcal }
        let d = record.cachedDistanceMeters, t = record.cachedDurationSeconds
        record.cachedAvgPaceSecPerKm = d > 0 ? t / (d / 1000) : 0
        try? context.save()
        RunEventLog.shared.record(
            "run.healed",
            String(format: "adopted Health workout onto stub row: %.2f km / %.0f kcal",
                   record.cachedDistanceMeters / 1000, record.cachedEnergyKcal))
    }

    /// Repair UNREADABLE runs already sitting in history, with no breadcrumb
    /// required.
    ///
    /// The marker is cleared immediately after the provisional save and BEFORE
    /// the summary work that crashes, so a marker-driven heal can never reach
    /// the runs that actually broke — his 29 and 31 August runs are already in
    /// history with no workout UUID and no series, and nothing was ever going
    /// to come back for them. This sweeps for that shape directly.
    ///
    /// Conservative on purpose: only rows with NO workout UUID and NO series
    /// (i.e. genuinely unrenderable), never test runs, and only adopting a
    /// Health workout that overlaps the row's own start time.
    static func healUnreadableRuns(context: ModelContext) async -> Int {
        let all = (try? context.fetch(FetchDescriptor<RunRecord>())) ?? []
        let stubs = all.filter {
            !$0.isTestData && $0.healthKitWorkoutUUID == nil && ($0.seriesBlob?.isEmpty ?? true)
                && $0.cachedDurationSeconds >= minMeaningfulSeconds
        }
        guard !stubs.isEmpty else { return 0 }
        let knownHK = Set(all.compactMap { $0.healthKitWorkoutUUID })
        let workouts = await HealthKitReader.shared.recentRunningWorkouts()
            .filter { !$0.isTest && !knownHK.contains($0.uuid) }
        guard !workouts.isEmpty else { return 0 }

        var used = Set<UUID>()
        var healed = 0
        for stub in stubs {
            let window = stub.startedAt.addingTimeInterval(-600)...stub.startedAt
                .addingTimeInterval(maxRunHours * 3600)
            guard let w = workouts
                .filter({ !used.contains($0.uuid) && window.contains($0.start) })
                .min(by: {
                    abs($0.start.timeIntervalSince(stub.startedAt))
                        < abs($1.start.timeIntervalSince(stub.startedAt))
                }) else { continue }
            used.insert(w.uuid)
            stub.healthKitWorkoutUUID = w.uuid
            if w.distanceMeters > 0 { stub.cachedDistanceMeters = w.distanceMeters }
            if w.durationSeconds > 0 { stub.cachedDurationSeconds = w.durationSeconds }
            if w.energyKcal > 0 { stub.cachedEnergyKcal = w.energyKcal }
            let d = stub.cachedDistanceMeters, t = stub.cachedDurationSeconds
            stub.cachedAvgPaceSecPerKm = d > 0 ? t / (d / 1000) : 0
            healed += 1
        }
        if healed > 0 {
            try? context.save()
            RunEventLog.shared.record("run.healedStubs", "repaired \(healed) unreadable run(s) from Health")
        }
        return healed
    }

    @discardableResult
    static func recoverIfNeeded(context: ModelContext) async -> Outcome {
        guard let marker = UnfinishedRunStore.pending else { return .nothingPending }

        // A run that only just started, or a test run, is not worth rescuing.
        let livedFor = marker.lastSeenAt.timeIntervalSince(marker.startedAt)
        if marker.isTest || livedFor < minMeaningfulSeconds {
            UnfinishedRunStore.clear()
            return .nothingPending
        }

        let existing = (try? context.fetch(FetchDescriptor<RunRecord>())) ?? []
        if let already = existing.first(where: { $0.id == marker.runId }) {
            // The row exists, but "exists" is not the same as "readable". A
            // provisional row written by the gate and never adopted by the
            // HealthKit pass has no workout UUID and (before this build) no
            // series, so the detail page renders blank — the 29/31 August
            // runs. If we can still find its workout, adopt it now rather than
            // leaving him with an empty page forever.
            if already.healthKitWorkoutUUID == nil {
                await Self.heal(already, marker: marker, existing: existing, context: context)
            }
            UnfinishedRunStore.clear()
            return .alreadyRecorded
        }
        let knownHK = Set(existing.compactMap { $0.healthKitWorkoutUUID })

        // Find the workout this run produced.
        let window = marker.startedAt.addingTimeInterval(-300)...marker.startedAt
            .addingTimeInterval(maxRunHours * 3600)
        let candidates = await HealthKitReader.shared.recentRunningWorkouts()
            .filter { !$0.isTest && !knownHK.contains($0.uuid) && window.contains($0.start) }

        // Prefer the workout that says it IS this run; otherwise the one that
        // started closest to when we did (the GymKit case).
        let match = candidates.first { $0.aarcRunId == marker.runId }
            ?? candidates.min {
                abs($0.start.timeIntervalSince(marker.startedAt))
                    < abs($1.start.timeIntervalSince(marker.startedAt))
            }

        guard let w = match else {
            // Keep the marker: HealthKit sync from the watch can lag, and a
            // later launch may well find it. Clearing here would throw away
            // the only pointer we have.
            RunEventLog.shared.record("run.recoverPending",
                                      "no Health workout yet for \(marker.runId.uuidString.prefix(8))")
            return .noWorkoutFound
        }

        let dist = w.distanceMeters
        let dur = w.durationSeconds
        let record = RunRecord(
            id: existing.contains(where: { $0.id == marker.runId }) ? UUID() : marker.runId,
            startedAt: w.start,
            endedAt: w.end,
            personality: marker.personalityId,
            isTestData: false,
            healthKitWorkoutUUID: w.uuid,
            runTypeRaw: w.runTypeRaw,
            cachedDistanceMeters: dist,
            cachedDurationSeconds: dur,
            cachedAvgPaceSecPerKm: dist > 0 ? dur / (dist / 1000) : 0,
            cachedEnergyKcal: w.energyKcal
        )
        context.insert(record)
        try? context.save()
        UnfinishedRunStore.clear()

        RunEventLog.shared.record(
            "run.recovered",
            String(format: "%.2f km / %.0f s from Health (%@)", dist / 1000, dur,
                   w.aarcRunId == marker.runId ? "aarc id" : "time match"))
        RunHistoryBackfill.backfillAll()
        return .recovered(distanceMeters: dist, durationSeconds: dur)
    }
}
