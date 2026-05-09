import Foundation

/// Messages exchanged between watchOS and iOS via WatchConnectivity.
/// Encoded with `JSONEncoder` and shipped through `WCSession.sendMessageData` (live)
/// or `transferUserInfo` (queued, guaranteed).
public enum WCMessage: Codable, Sendable {
    // Phone → Watch
    /// Phone is initiating a run. Watch should skip the preparing phase
    /// because the phone already has a script ready and stored locally.
    case startWorkout(runId: UUID, runType: RunType, personalityId: String)
    /// Phone finished generating a script for a watch-initiated request.
    case scriptReady(scriptId: String)
    /// Phone failed to generate a script. The watch should surface the
    /// reason and let the user retry or proceed without a coach.
    case scriptFailed(reason: String)
    case endWorkout
    case hapticCue(kind: HapticCueKind)
    case companionMessageDispatched(messageId: UUID)
    case hello(text: String)

    // Watch → Phone
    /// Watch user tapped Start. Phone should generate a script for this
    /// run and reply with .scriptReady or .scriptFailed.
    case prepareWorkout(runId: UUID, runType: RunType, personalityId: String)
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
