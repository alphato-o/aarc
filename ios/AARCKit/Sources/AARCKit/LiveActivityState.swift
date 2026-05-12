import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Static config + dynamic state for the iPhone Live Activity that
/// surfaces an in-progress run on the lock screen and in the Dynamic
/// Island. Lives in AARCKit so both the main app (publisher) and the
/// AARCLiveActivity widget extension (subscriber) compile against the
/// same definition.
public struct LiveActivityAttributes: Codable, Sendable, Hashable {
    /// Stable for the lifetime of the activity.
    public struct ContentState: Codable, Sendable, Hashable {
        public let elapsedSeconds: TimeInterval
        public let distanceMeters: Double
        /// nil when unknown (very early in run, GPS still warming).
        public let currentPaceSecPerKm: Double?
        /// Cumulative average since the start. 0 when distance is 0.
        public let avgPaceSecPerKm: Double
        public let currentHR: Double?
        /// Plan-aware target. nil for open runs.
        public let targetDistanceMeters: Double?
        public let targetSeconds: TimeInterval?
        public let isPaused: Bool

        public init(
            elapsedSeconds: TimeInterval,
            distanceMeters: Double,
            currentPaceSecPerKm: Double?,
            avgPaceSecPerKm: Double,
            currentHR: Double?,
            targetDistanceMeters: Double?,
            targetSeconds: TimeInterval?,
            isPaused: Bool
        ) {
            self.elapsedSeconds = elapsedSeconds
            self.distanceMeters = distanceMeters
            self.currentPaceSecPerKm = currentPaceSecPerKm
            self.avgPaceSecPerKm = avgPaceSecPerKm
            self.currentHR = currentHR
            self.targetDistanceMeters = targetDistanceMeters
            self.targetSeconds = targetSeconds
            self.isPaused = isPaused
        }

        /// Plan progress as 0…1, or nil for open runs.
        public var planProgress: Double? {
            if let target = targetDistanceMeters, target > 0 {
                return min(1, distanceMeters / target)
            }
            if let target = targetSeconds, target > 0 {
                return min(1, elapsedSeconds / target)
            }
            return nil
        }
    }

    public let runId: UUID
    public let personalityId: String
    public let runType: RunType
    public let planKind: RunPlan.Kind
    public let startedAt: Date

    public init(
        runId: UUID,
        personalityId: String,
        runType: RunType,
        planKind: RunPlan.Kind,
        startedAt: Date
    ) {
        self.runId = runId
        self.personalityId = personalityId
        self.runType = runType
        self.planKind = planKind
        self.startedAt = startedAt
    }
}

#if canImport(ActivityKit)
extension LiveActivityAttributes: ActivityAttributes {}
#endif

public extension LiveActivityAttributes.ContentState {
    /// "5:32" / "12:04" style. Bare seconds-per-km input.
    static func formatPace(_ secPerKm: Double?) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let total = Int(secPerKm.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// "12:34" or "1:02:03" if it crosses an hour.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "5.32 km" / "0.40 km"
    static func formatDistance(_ meters: Double) -> String {
        String(format: "%.2f km", meters / 1000)
    }
}
