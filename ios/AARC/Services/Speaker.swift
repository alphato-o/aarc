import Foundation
import Observation

/// Single dispatch point for "speak this line". Picks the user's
/// preferred backend (premium ElevenLabs voice or Apple AVSpeech).
/// Anything in the app that wants AARC to say something should call
/// `Speaker.shared.speak(text)` rather than reaching into a TTS impl
/// directly.
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

    /// Speak the line via the user's chosen backend. Always async-safe;
    /// RemoteTTS network calls happen in a detached Task.
    func speak(_ text: String) {
        if preferRemoteVoice {
            Task { await RemoteTTS.shared.speak(text) }
        } else {
            LocalTTS.shared.speak(text)
        }
    }

    /// Stop everything currently speaking, drop any queued audio.
    func stopAll() {
        RemoteTTS.shared.stopAll()
        LocalTTS.shared.stopAll()
    }
}
