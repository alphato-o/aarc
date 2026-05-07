import Foundation

public struct Split: Codable, Sendable, Hashable {
    public let kmIndex: Int
    public let durationSeconds: Double
    public let paceSecPerKm: Double
    public let avgHeartRate: Double?

    public init(kmIndex: Int, durationSeconds: Double, paceSecPerKm: Double, avgHeartRate: Double?) {
        self.kmIndex = kmIndex
        self.durationSeconds = durationSeconds
        self.paceSecPerKm = paceSecPerKm
        self.avgHeartRate = avgHeartRate
    }
}

/// 1Hz snapshot published by the watch's `WorkoutSessionHost` to the phone.
/// All numeric values originate from `HKLiveWorkoutBuilder` — never computed on the phone.
public struct LiveMetrics: Codable, Sendable, Hashable {
    public let elapsed: TimeInterval
    public let distanceMeters: Double
    public let currentPaceSecPerKm: Double?
    public let avgPaceSecPerKm: Double
    public let currentHeartRate: Double?
    public let energyKcal: Double
    public let lastSplit: Split?
    public let state: WorkoutState

    public init(
        elapsed: TimeInterval,
        distanceMeters: Double,
        currentPaceSecPerKm: Double?,
        avgPaceSecPerKm: Double,
        currentHeartRate: Double?,
        energyKcal: Double,
        lastSplit: Split?,
        state: WorkoutState
    ) {
        self.elapsed = elapsed
        self.distanceMeters = distanceMeters
        self.currentPaceSecPerKm = currentPaceSecPerKm
        self.avgPaceSecPerKm = avgPaceSecPerKm
        self.currentHeartRate = currentHeartRate
        self.energyKcal = energyKcal
        self.lastSplit = lastSplit
        self.state = state
    }
}
