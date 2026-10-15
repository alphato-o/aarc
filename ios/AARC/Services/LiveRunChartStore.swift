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
    /// Mean of the 1 Hz pace ticks inside this bucket, not the single value
    /// at the crossing: that one value hid a finishing surge (15 Oct).
    let paceSecPerKm: Double?
    /// Fastest tick inside the bucket, for the surge the mean still softens.
    var fastestPaceSecPerKm: Double? = nil
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
        resetTicks()
    }

    /// Called from LiveMetricsConsumer.ingest. Cheap when no new
    /// bucket has been crossed.
    private var tickPaceSum: Double = 0
    private var tickPaceCount: Int = 0
    private var tickPaceMin: Double = .infinity
    private var tickHRSum: Double = 0
    private var tickHRCount: Int = 0

    private func accumulate(_ metrics: LiveMetrics) {
        if let p = metrics.currentPaceSecPerKm, p > 0 {
            tickPaceSum += p; tickPaceCount += 1; tickPaceMin = min(tickPaceMin, p)
        }
        if let h = metrics.currentHeartRate, h > 0 { tickHRSum += h; tickHRCount += 1 }
    }

    private func resetTicks() {
        tickPaceSum = 0; tickPaceCount = 0; tickPaceMin = .infinity; tickHRSum = 0; tickHRCount = 0
    }

    /// The run ended inside a bucket: record what it held so the last
    /// hundred metres (where the surge lives) reach the chart.
    func finishPartialBucket(_ metrics: LiveMetrics?) {
        guard tickPaceCount > 0 || tickHRCount > 0 else { return }
        let idx = lastBucketIndex + 1
        samples.append(LiveRunChartSample(
            bucketIndex: idx,
            heartRate: tickHRCount > 0 ? tickHRSum / Double(tickHRCount) : metrics?.currentHeartRate,
            paceSecPerKm: tickPaceCount > 0 ? tickPaceSum / Double(tickPaceCount) : metrics?.currentPaceSecPerKm,
            fastestPaceSecPerKm: tickPaceCount > 0 ? tickPaceMin : nil,
            recordedAt: .now))
        lastBucketIndex = idx
        resetTicks()
    }

    func ingest(_ metrics: LiveMetrics) {
        let bucketIndex = Int(metrics.distanceMeters / 100)
        accumulate(metrics)
        guard bucketIndex > lastBucketIndex else { return }

        // Backfill any buckets we skipped (e.g., the metric stream
        // hiccupped and distance jumped by 300m). Stamp each with the
        // CURRENT metrics — best signal we have for the in-between
        // positions, and avoids gaps in the chart.
        let firstNew = lastBucketIndex + 1
        for idx in firstNew...bucketIndex {
            // The bucket just completed gets its own ticks' mean; any
            // skipped buckets get the current metrics as before.
            let completed = idx == firstNew && tickPaceCount > 0
            let sample = LiveRunChartSample(
                bucketIndex: idx,
                heartRate: completed && tickHRCount > 0 ? tickHRSum / Double(tickHRCount) : metrics.currentHeartRate,
                paceSecPerKm: completed ? tickPaceSum / Double(tickPaceCount) : metrics.currentPaceSecPerKm,
                fastestPaceSecPerKm: completed ? tickPaceMin : nil,
                recordedAt: .now
            )
            samples.append(sample)
        }
        resetTicks()
        lastBucketIndex = bucketIndex

        // Defensive cap.
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}
