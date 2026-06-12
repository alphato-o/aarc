import Foundation
import SwiftData

/// Recovers runs that exist as Apple Health workouts but were never recorded
/// by AARC — e.g. a run the WATCH tracked and saved while the phone↔watch
/// link was broken (so the phone never created a RunRecord). Scans Health,
/// creates RunRecords for any running workout not already in the app, and
/// syncs the recovered runs to the cloud. Skips AARC test workouts.
@MainActor
enum HealthImporter {
    /// Imports missing workouts. Returns the number recovered.
    static func importMissing(context: ModelContext) async -> Int {
        let summaries = await HealthKitReader.shared.recentRunningWorkouts()
        guard !summaries.isEmpty else { return 0 }

        let existing = (try? context.fetch(FetchDescriptor<RunRecord>())) ?? []
        let knownHKUUIDs = Set(existing.compactMap { $0.healthKitWorkoutUUID })
        let knownIds = Set(existing.map { $0.id })

        var imported = 0
        for w in summaries where !w.isTest && !knownHKUUIDs.contains(w.uuid) {
            let dist = w.distanceMeters
            let dur = w.durationSeconds
            // Prefer the embedded AARC run id, but never collide with an
            // existing row's id (the unique attribute).
            let id = (w.aarcRunId.map { knownIds.contains($0) ? UUID() : $0 }) ?? UUID()
            let record = RunRecord(
                id: id,
                startedAt: w.start,
                endedAt: w.end,
                personality: "roast_coach",
                isTestData: false,
                healthKitWorkoutUUID: w.uuid,
                runTypeRaw: w.runTypeRaw,
                cachedDistanceMeters: dist,
                cachedDurationSeconds: dur,
                cachedAvgPaceSecPerKm: dist > 0 ? dur / (dist / 1000) : 0,
                cachedEnergyKcal: w.energyKcal
            )
            context.insert(record)
            imported += 1
        }

        if imported > 0 {
            try? context.save()
            // Push the recovered runs' performance to the cloud dashboard too.
            RunHistoryBackfill.backfillAll()
        }
        return imported
    }
}
