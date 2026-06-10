import Foundation

/// Payloads sent over the HKWorkoutSession mirroring data channel
/// (watchOS 10 / iOS 17 `sendToRemoteWorkoutSession`). This channel is
/// the modern, Apple-blessed replacement for WatchConnectivity during a
/// live workout: the system itself launches the iPhone app in the
/// background to deliver the mirrored session, keeps the session state
/// (running/paused/ended) in sync, and auto-reconnects after Bluetooth
/// drops. WC remains as a redundant fallback transport.
///
/// Budget: HealthKit allows at most 100 KB per 10-second window on this
/// channel — these payloads are tiny (sub-KB), so 1 Hz metrics are far
/// inside the limit.
public enum MirrorPayload: Codable, Sendable {
    /// Sent once right after the watch starts mirroring: identifies the
    /// run so the phone can key its engines (script, coach, Live
    /// Activity) to the same runId without relying on a WC round-trip.
    case identity(runId: UUID, runType: RunType, personalityId: String, startedAt: Date)
    /// 1 Hz live metrics — same snapshot the WC path carries.
    case metrics(LiveMetrics)
}
