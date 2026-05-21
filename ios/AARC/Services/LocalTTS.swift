import Foundation
import AVFoundation

/// Wraps `AVSpeechSynthesizer` to speak companion lines. Picks the
/// highest-quality installed voice for the user's locale. The audio
/// session and serialisation are owned by `VoiceFeedbackQueue`; this
/// class just speaks a single utterance and returns when it's done.
@MainActor
final class LocalTTS: NSObject {
    static let shared = LocalTTS()

    private let synthesizer = AVSpeechSynthesizer()
    private let preferredVoice: AVSpeechSynthesisVoice?

    /// Resumed when the current utterance finishes (or is cancelled by
    /// `stopAll`). The queue's serial playback loop awaits this so the
    /// next item only starts once the current one is fully spoken.
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Read-only summary of the chosen voice for diagnostic UI.
    var voiceDescription: String {
        guard let v = preferredVoice else { return "system default" }
        let q: String
        switch v.quality {
        case .premium: q = "premium"
        case .enhanced: q = "enhanced"
        case .default: q = "default"
        @unknown default: q = "?"
        }
        return "\(v.name) (\(v.language), \(q))"
    }

    override init() {
        self.preferredVoice = Self.pickBestVoice()
        super.init()
        self.synthesizer.delegate = self
    }

    /// Speak a single line and return once the utterance is fully spoken
    /// (or cancelled). Mute is handled upstream by VoiceFeedbackQueue —
    /// muted lines never reach here.
    func play(text: String) async {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // 200ms grace before/after so the duck-in / duck-out doesn't
        // clip the first or last syllable.
        utterance.preUtteranceDelay = 0.2
        utterance.postUtteranceDelay = 0.2

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.playbackContinuation = cont
            synthesizer.speak(utterance)
        }
    }

    /// Stop everything immediately, drop the queue. Resumes the in-flight
    /// continuation so the queue's playback loop unblocks.
    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Voice selection

    private static func pickBestVoice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
        if let premium = candidates.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) { return enhanced }
        return candidates.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension LocalTTS: @preconcurrency AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let cont = self.playbackContinuation {
                self.playbackContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let cont = self.playbackContinuation {
                self.playbackContinuation = nil
                cont.resume()
            }
        }
    }
}
