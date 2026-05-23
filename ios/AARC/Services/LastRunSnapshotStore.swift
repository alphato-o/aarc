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

    static func write(from record: RunRecord, paceSplits: [Double]?) {
        let snapshot = LastRunSnapshot(
            runId: record.id,
            startedAt: record.startedAt,
            endedAt: record.endedAt ?? record.startedAt,
            distanceMeters: record.cachedDistanceMeters,
            durationSeconds: record.cachedDurationSeconds,
            avgPaceSecPerKm: record.cachedAvgPaceSecPerKm,
            energyKcal: record.cachedEnergyKcal,
            runTypeRaw: record.runTypeRaw,
            paceSplits: paceSplits
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
            log.info("Wrote LastRunSnapshot: distance=\(snapshot.distanceMeters, privacy: .public)m, splits=\(snapshot.paceSplits?.count ?? 0, privacy: .public)")
        } catch {
            log.error("Failed to write LastRunSnapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Backfill the widget snapshot from existing SwiftData history.
    /// Called on app launch so runs that pre-date the widget (or that
    /// landed while the App Group entitlement wasn't yet provisioned)
    /// surface in the widget without requiring a fresh run.
    ///
    /// Historical runs don't have access to the in-memory
    /// LiveRunChartStore samples anymore, so paceSplits is nil — the
    /// widget renders without the sparkline. We could re-derive splits
    /// from HealthKit here, but that's heavy on launch and not
    /// worth blocking the UI for. A later run will fill in splits.
    static func backfillFromHistory() {
        let context = PersistenceStore.shared.container.mainContext
        var descriptor = FetchDescriptor<RunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            let runs = try context.fetch(descriptor)
            guard let latest = runs.first else {
                log.info("backfill: no runs in history, nothing to write")
                return
            }
            log.info("backfill: writing snapshot for run \(latest.id, privacy: .public)")
            write(from: latest, paceSplits: nil)
        } catch {
            log.error("backfill: fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Compute per-km pace splits from the in-run sample buffer.
    /// Each finished km gets one entry (sec/km). Returns nil when the
    /// store doesn't have enough samples for at least one full km.
    static func paceSplitsFromLiveStore() -> [Double]? {
        let samples = LiveRunChartStore.shared.samples
        guard !samples.isEmpty else { return nil }
        // Bucket the 100m samples into km buckets. Within each km
        // bucket we average the per-100m pace readings, ignoring any
        // that didn't have a valid pace (early-run, stationary, etc.).
        var bucketSum: [Int: (sum: Double, count: Int)] = [:]
        for sample in samples {
            guard let pace = sample.paceSecPerKm, pace > 0 else { continue }
            let kmIndex = sample.bucketIndex / 10  // 10 × 100m per km
            var existing = bucketSum[kmIndex] ?? (0, 0)
            existing.sum += pace
            existing.count += 1
            bucketSum[kmIndex] = existing
        }
        guard !bucketSum.isEmpty else { return nil }
        // Only emit splits for kms with enough samples (≥6 of the 10
        // possible per-100m buckets) so we don't show garbage for the
        // last partial km.
        let sorted = bucketSum.sorted { $0.key < $1.key }
        var splits: [Double] = []
        for (_, agg) in sorted where agg.count >= 6 {
            splits.append(agg.sum / Double(agg.count))
        }
        return splits.isEmpty ? nil : splits
    }
}
