import Foundation
import Observation
import AARCKit

/// One row in the live in-run chart. Each represents a 100m bucket
/// crossed during the run; samples accumulate left-to-right as the
/// runner moves. Once recorded the values are frozen so the chart
/// behaves like a real telemetry trace — bar 3 doesn't move when bar
/// 12 lands.
struct LiveRunChartSample: Identifiable, Sendable, Hashable {
    /// 100m bucket index. `distanceKm = Double(bucketIndex) * 0.1`.
    let bucketIndex: Int
    let heartRate: Double?
    let paceSecPerKm: Double?
    let recordedAt: Date

    var id: Int { bucketIndex }
    var distanceKm: Double { Double(bucketIndex) * 0.1 }
}

/// Collects per-100m samples during a run for the in-cockpit live
/// chart. Updated from `LiveMetricsConsumer.ingest` on every 1Hz tick
/// from the watch (or phone-only session); only commits a new sample
/// when the runner has actually crossed a new 100m boundary. Resets
/// on run start so the chart starts blank every run.
@Observable
@MainActor
final class LiveRunChartStore {
    static let shared = LiveRunChartStore()

    /// Locked-in samples, ordered by bucketIndex ascending.
    private(set) var samples: [LiveRunChartSample] = []

    /// The last bucket that's been recorded. -1 means no sample yet.
    private var lastBucketIndex: Int = -1

    /// Optional cap so a runner doing 50km doesn't accumulate 500
    /// objects and rebuild the entire Chart on every frame. The Swift
    /// Charts framework handles this fine in practice — capped at
    /// 1000 anyway as a defensive ceiling for the next decade of GPS
    /// drift around 100km ultras.
    private let maxSamples = 1000

    func reset() {
        samples.removeAll(keepingCapacity: true)
        lastBucketIndex = -1
    }

    /// Called from LiveMetricsConsumer.ingest. Cheap when no new
    /// bucket has been crossed.
    func ingest(_ metrics: LiveMetrics) {
        let bucketIndex = Int(metrics.distanceMeters / 100)
        guard bucketIndex > lastBucketIndex else { return }

        // Backfill any buckets we skipped (e.g., the metric stream
        // hiccupped and distance jumped by 300m). Stamp each with the
        // CURRENT metrics — best signal we have for the in-between
        // positions, and avoids gaps in the chart.
        let firstNew = lastBucketIndex + 1
        for idx in firstNew...bucketIndex {
            let sample = LiveRunChartSample(
                bucketIndex: idx,
                heartRate: metrics.currentHeartRate,
                paceSecPerKm: metrics.currentPaceSecPerKm,
                recordedAt: .now
            )
            samples.append(sample)
        }
        lastBucketIndex = bucketIndex

        // Defensive cap.
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}
