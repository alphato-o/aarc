import Foundation

/// Messages exchanged between watchOS and iOS via WatchConnectivity.
/// Encoded with `JSONEncoder` and shipped through `WCSession.sendMessageData` (live)
/// or `transferUserInfo` (queued, guaranteed).
public enum WCMessage: Codable, Sendable {
    // Phone → Watch
    /// Phone is initiating a run. Watch should skip the preparing phase
    /// because the phone already has a script ready and stored locally.
    case startWorkout(runId: UUID, runType: RunType, personalityId: String)
    /// Phone gave up waiting for the watch and fell back to phone-only.
    /// If the watch is still pending/counting down this runId, abandon
    /// it; if it just started it, end + discard — never double-track.
    case cancelStart(runId: UUID)
    /// Phone finished generating a script for a watch-initiated request.
    case scriptReady(scriptId: String)
    /// Phone failed to generate a script. The watch should surface the
    /// reason and let the user retry or proceed without a coach.
    case scriptFailed(reason: String)
    case endWorkout
    case hapticCue(kind: HapticCueKind)
    case companionMessageDispatched(messageId: UUID)
    case hello(text: String)
    /// The coach line currently on screen, mirrored to the watch so the runner
    /// can read + heart it without the phone. Empty text clears it.
    case coachLine(id: UUID, text: String, who: String)

    // Watch → Phone
    /// Watch received + accepted a startWorkout command and is counting
    /// down. Early ACK so the phone knows the handover landed within ~1s
    /// instead of waiting for the HK session to actually start.
    case startAck(runId: UUID)
    /// Watch received a startWorkout but can't act on it (already
    /// running, HealthKit denied, stale command…). Lets the phone fall
    /// back immediately instead of waiting out a timeout.
    case startDeclined(runId: UUID, reason: String)
    /// Watch user tapped Start. Phone should generate a script for this
    /// run and reply with .scriptReady or .scriptFailed.
    case prepareWorkout(runId: UUID, runType: RunType, personalityId: String)
    case workoutStarted(runId: UUID, startedAt: Date)
    case workoutPaused
    case workoutResumed
    case workoutEnded(healthKitWorkoutUUID: UUID)
    case liveMetrics(LiveMetrics)
    /// Runner hearted the current coach line from the watch. Carries text+who
    /// so the phone can record the like without a lookup.
    case heartLine(id: UUID, text: String, who: String)
}

public enum HapticCueKind: String, Codable, Sendable {
    case kmMilestone
    case pacingWarning
    case fuelingReminder
    case hydrationReminder
}
