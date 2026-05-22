import Foundation
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
            // App Group entitlement not provisioned yet — skip silently
            // rather than crash on the first run after install.
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Non-fatal — the next save attempt will write again.
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
