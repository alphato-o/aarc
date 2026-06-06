import Foundation
import Observation

/// Single dispatch point for "speak this line." Enqueues the request into
/// `VoiceFeedbackQueue`, which serialises playback and applies priority
/// + preemption + staleness rules. Picks the user's preferred backend
/// (premium ElevenLabs voice or Apple AVSpeech) when the queue actually
/// plays the item.
@Observable
@MainActor
final class Speaker {
    static let shared = Speaker()

    private static let kPreferRemoteVoice = "aarc.audio.preferRemoteVoice"

    /// True → ElevenLabs (RemoteTTS). False → Apple AVSpeech (LocalTTS).
    /// Persisted; defaults to true since the founder explicitly opted in
    /// by setting up an ElevenLabs key.
    var preferRemoteVoice: Bool {
        didSet { UserDefaults.standard.set(preferRemoteVoice, forKey: Self.kPreferRemoteVoice) }
    }

    init() {
        let store = UserDefaults.standard
        if store.object(forKey: Self.kPreferRemoteVoice) == nil {
            store.set(true, forKey: Self.kPreferRemoteVoice)
        }
        self.preferRemoteVoice = store.bool(forKey: Self.kPreferRemoteVoice)
    }

    /// Enqueue a line for the queue to play when it's safe. Returns
    /// immediately — actual audio is dispatched by VoiceFeedbackQueue's
    /// serial playback loop and may be delayed (waiting on higher-priority
    /// items), dropped (stale / dedup), or preempted (lower-priority lines
    /// cut off by a milestone).
    func speak(
        _ text: String,
        priority: VoicePriority = .coaching,
        source: String = "speaker",
        dedupKey: String? = nil,
        expiresAfter: TimeInterval? = nil,
        voiceId: String? = nil,
        segmentId: UUID? = nil
    ) {
        let item = VoiceItem(
            text: text,
            priority: priority,
            source: source,
            dedupKey: dedupKey,
            expiresAfter: expiresAfter,
            voiceId: voiceId,
            segmentId: segmentId
        )
        VoiceFeedbackQueue.shared.enqueue(item)
    }

    /// Stop everything currently speaking and clear the queue.
    func stopAll() {
        VoiceFeedbackQueue.shared.stopAll()
    }

    // MARK: - Queue-internal helpers

    /// Called by VoiceFeedbackQueue's serial loop to actually emit one
    /// item's audio. Returns when the audio is fully done playing (or
    /// has fallen back to LocalTTS, which also awaits). Not part of the
    /// public Speaker API; callers should always go through `speak(_:)`.
    ///
    /// `onAudioStart` fires exactly once at the moment audio becomes
    /// audible — used by the queue to surface the in-run subtitle bar
    /// in sync with the first syllable rather than at the start of the
    /// fetch.
    func playSync(
        text: String,
        voiceId: String? = nil,
        preferRemoteOverride: Bool? = nil,
        onAudioStart: (@MainActor @Sendable () -> Void)? = nil
    ) async {
        // Defensive early-out: the queue cancels playbackTask on
        // stopAll, and we don't want to start a backend mid-cancel.
        if Task.isCancelled { return }
        let useRemote = preferRemoteOverride ?? preferRemoteVoice
        if useRemote {
            await RemoteTTS.shared.play(
                text: text,
                voiceId: voiceId ?? RemoteTTS.voiceId,
                onAudioStart: onAudioStart
            )
        } else {
            await LocalTTS.shared.play(text: text, onAudioStart: onAudioStart)
        }
    }

    /// Stop the currently-playing backend without touching the queue.
    /// Used by VoiceFeedbackQueue's preemption path: clear the active
    /// utterance so the higher-priority item can take over.
    func stopActiveBackend() {
        RemoteTTS.shared.stopAll()
        LocalTTS.shared.stopAll()
    }
}
