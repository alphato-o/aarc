import Foundation

/// Messages exchanged between watchOS and iOS via WatchConnectivity.
/// Encoded with `JSONEncoder` and shipped through `WCSession.sendMessageData` (live)
/// or `transferUserInfo` (queued, guaranteed).
public enum WCMessage: Codable, Sendable {
    // Phone → Watch
    case startWorkout(runId: UUID, personalityId: String, mode: RunMode)
    case endWorkout
    case hapticCue(kind: HapticCueKind)
    case companionMessageDispatched(messageId: UUID)
    case hello(text: String)

    // Watch → Phone
    case workoutStarted(runId: UUID, startedAt: Date)
    case workoutPaused
    case workoutResumed
    case workoutEnded(healthKitWorkoutUUID: UUID)
    case liveMetrics(LiveMetrics)
}

public enum HapticCueKind: String, Codable, Sendable {
    case kmMilestone
    case pacingWarning
    case fuelingReminder
    case hydrationReminder
}
