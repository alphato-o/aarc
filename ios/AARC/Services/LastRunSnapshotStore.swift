import Foundation
import SwiftData
import OSLog
import WidgetKit
import AARCKit

/// Writes the latest finished `RunRecord` to the App Group container
/// so the home-screen widget (in the AARCLiveActivity extension) can
/// render it. After each save, asks WidgetKit to reload all timelines
/// so the widget updates immediately rather than at the next system
/// refresh tick.
///
/// Per-km pace splits are derived from `LiveRunChartStore.samples`
/// — the same per-100m buffer the in-run chart uses. Splits are
/// captured at run-end, BEFORE LiveRunChartStore resets for the next
/// run.
@MainActor
enum LastRunSnapshotStore {
    private static let log = Logger(subsystem: "club.aarun.AARC", category: "WidgetSnapshot")

    static func write(
        from record: RunRecord,
        paceSplits: [Double]?,
        hrSplits: [Double]? = nil,
        paceFine: [Double]? = nil,
        hrFine: [Double]? = nil
    ) {
        let snapshot = LastRunSnapshot(
            runId: record.id,
            startedAt: record.startedAt,
            endedAt: record.endedAt ?? record.startedAt,
            distanceMeters: record.cachedDistanceMeters,
            durationSeconds: record.cachedDurationSeconds,
            avgPaceSecPerKm: record.cachedAvgPaceSecPerKm,
            energyKcal: record.cachedEnergyKcal,
            runTypeRaw: record.runTypeRaw,
            paceSplits: paceSplits,
            hrSplits: hrSplits,
            paceFine: paceFine,
            hrFine: hrFine
        )

        guard let url = LastRunSnapshot.sharedFileURL() else {
            // App Group entitlement not provisioned yet — happens when
            // the App Group hasn't been registered in the Apple Developer
            // Portal under Identifiers → App Groups, OR when the dev
            // profile hasn't been refreshed since the entitlement was
            // added. The widget will keep showing the empty state until
            // this is fixed. See the commit message that introduced the
            // widget for the manual steps.
            log.error("App Group container URL is nil — entitlement not provisioned for \(LastRunSnapshot.appGroupId, privacy: .public)")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            log.error("Failed to encode LastRunSnapshot")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
            log.info("Wrote LastRunSnapshot: distance=\(snapshot.distanceMeters, privacy: .public)m, paceSplits=\(snapshot.paceSplits?.count ?? 0, privacy: .public), hrSplits=\(snapshot.hrSplits?.count ?? 0, privacy: .public), paceFine=\(snapshot.paceFine?.count ?? 0, privacy: .public), hrFine=\(snapshot.hrFine?.count ?? 0, privacy: .public)")
        } catch {
            log.error("Failed to write LastRunSnapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Backfill the widget snapshot from existing SwiftData history.
    /// Called on app launch so runs that pre-date the widget (or that
    /// landed while the App Group entitlement wasn't yet provisioned)
    /// surface in the widget without requiring a fresh run.
    ///
    /// Two-phase:
    /// 1. Write the snapshot immediately with stats only (no splits).
    ///    The widget renders the dual-line chart hidden but distance/
    ///    time/pace/kcal show right away.
    /// 2. Asynchronously query HealthKit for the workout's per-km
    ///    pace + HR splits, then rewrite the snapshot WITH splits.
    ///    The widget gets a second reload and the chart appears.
    ///
    /// Splitting into two phases keeps the launch path fast (no
    /// HK round-trip blocks initial render) but the chart still
    /// catches up within a few seconds.
    static func backfillFromHistory() {
        let context = PersistenceStore.shared.container.mainContext
        var descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            let runs = try context.fetch(descriptor)
            guard let latest = runs.first else {
                log.info("backfill: no runs in history, nothing to write")
                return
            }
            log.info("backfill: writing stats-only snapshot for run \(latest.id, privacy: .public)")
            write(from: latest, paceSplits: nil, hrSplits: nil)

            // Phase 2: fill in splits from HK if available.
            guard let hkUUID = latest.healthKitWorkoutUUID else { return }
            Task { @MainActor in
                await backfillSplitsAsync(record: latest, hkUUID: hkUUID)
            }
        } catch {
            log.error("backfill: fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func backfillSplitsAsync(record: RunRecord, hkUUID: UUID) async {
        do {
            guard let workout = try await HealthKitReader.shared.fetchWorkout(uuid: hkUUID) else {
                log.info("backfill: HK workout not yet available for \(hkUUID, privacy: .public)")
                return
            }
            let splits = try await HealthKitReader.shared.fetchPerKmSplits(workout: workout)
            guard !splits.pace.isEmpty else {
                log.info("backfill: HK returned empty splits — run < 1 km")
                return
            }
            let hrHasAny = splits.hr.contains { $0 > 0 }

            // Also pull the fine (per-100m) arrays for the smooth chart.
            // The partial last km is included via this call so the
            // chart extends to the right edge instead of stopping at
            // the last completed km.
            let fine = try await HealthKitReader.shared.fetchFineSplits(workout: workout)
            let fineHrHasAny = fine.hr.contains { $0 > 0 }

            log.info("backfill: HK splits ready — pace=\(splits.pace.count, privacy: .public), hr=\(hrHasAny ? splits.hr.count : 0, privacy: .public), paceFine=\(fine.pace.count, privacy: .public), hrFine=\(fineHrHasAny ? fine.hr.count : 0, privacy: .public)")
            write(
                from: record,
                paceSplits: splits.pace,
                hrSplits: hrHasAny ? splits.hr : nil,
                paceFine: fine.pace.isEmpty ? nil : fine.pace,
                hrFine: fineHrHasAny ? fine.hr : nil
            )
        } catch {
            log.error("backfill splits async: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Per-100m pace + HR series straight from the in-run sample
    /// buffer. LiveRunChartStore is already binned per-100m, so each
    /// sample maps 1:1 to a paceFine / hrFine entry. Zero entries
    /// indicate gaps (sample missing pace or HR — stationary, sensor
    /// dropout, etc.). Returns (nil, nil) when nothing is available.
    static func fineSeriesFromLiveStore() -> (pace: [Double]?, hr: [Double]?) {
        let samples = LiveRunChartStore.shared.samples
        guard !samples.isEmpty else { return (nil, nil) }
        // Samples should already be in bucketIndex order; sort defensively.
        let sorted = samples.sorted { $0.bucketIndex < $1.bucketIndex }
        var pace: [Double] = []
        var hr: [Double] = []
        for sample in sorted {
            pace.append(sample.paceSecPerKm ?? 0)
            hr.append(sample.heartRate ?? 0)
        }
        let hrHasAny = hr.contains { $0 > 0 }
        return (pace, hrHasAny ? hr : nil)
    }

    /// Compute aligned per-km pace + HR splits from the in-run sample
    /// buffer. Each finished km gets one entry. Returns nil arrays
    /// when the store doesn't have enough samples for at least one
    /// full km, OR when no samples carried HR data (HR strap dropout).
    static func splitsFromLiveStore() -> (pace: [Double]?, hr: [Double]?) {
        let samples = LiveRunChartStore.shared.samples
        guard !samples.isEmpty else { return (nil, nil) }
        // Bucket the 100m samples into km buckets and average within.
        var paceBucket: [Int: (sum: Double, count: Int)] = [:]
        var hrBucket: [Int: (sum: Double, count: Int)] = [:]
        for sample in samples {
            let kmIndex = sample.bucketIndex / 10  // 10 × 100m per km
            if let pace = sample.paceSecPerKm, pace > 0 {
                var existing = paceBucket[kmIndex] ?? (0, 0)
                existing.sum += pace
                existing.count += 1
                paceBucket[kmIndex] = existing
            }
            if let hr = sample.heartRate, hr > 0 {
                var existing = hrBucket[kmIndex] ?? (0, 0)
                existing.sum += hr
                existing.count += 1
                hrBucket[kmIndex] = existing
            }
        }
        // Only emit splits for kms with ≥6 of 10 possible per-100m
        // buckets, so we don't surface garbage for a partial last km.
        let completedKmIndices = paceBucket
            .filter { $0.value.count >= 6 }
            .keys
            .sorted()
        guard !completedKmIndices.isEmpty else { return (nil, nil) }
        let pace = completedKmIndices.map { idx -> Double in
            let agg = paceBucket[idx]!
            return agg.sum / Double(agg.count)
        }
        // HR is aligned with pace — same km indices. Missing km = 0
        // (widget chart skips zeros).
        let hr = completedKmIndices.map { idx -> Double in
            guard let agg = hrBucket[idx], agg.count > 0 else { return 0 }
            return agg.sum / Double(agg.count)
        }
        let hrHasAny = hr.contains { $0 > 0 }
        return (pace, hrHasAny ? hr : nil)
    }
}
