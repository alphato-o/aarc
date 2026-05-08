import Foundation
import AVFoundation

/// Wraps `AVSpeechSynthesizer` to speak companion lines. Picks the
/// highest-quality installed voice for the user's locale, ducks
/// surrounding audio via `AudioPlaybackManager`, and deactivates the
/// session shortly after the queue empties so other apps recover their
/// volume cleanly.
@MainActor
final class LocalTTS: NSObject {
    static let shared = LocalTTS()

    private let synthesizer = AVSpeechSynthesizer()
    private let preferredVoice: AVSpeechSynthesisVoice?
    private var pendingDeactivate: Task<Void, Never>?

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

    /// Speak a line. No-op when muted. Activates the audio session so
    /// background music ducks, queues the utterance via the system
    /// synthesizer.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        guard !AudioPlaybackManager.shared.isMuted else { return }

        AudioPlaybackManager.shared.activate()
        cancelPendingDeactivate()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // 200ms grace before/after so the duck-in / duck-out doesn't
        // clip the first or last syllable.
        utterance.preUtteranceDelay = 0.2
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    /// Stop everything immediately, drop the queue.
    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        cancelPendingDeactivate()
        AudioPlaybackManager.shared.deactivate()
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

    // MARK: - Lazy deactivate

    /// Schedule a delayed deactivate. If another utterance is enqueued
    /// before the delay elapses, we cancel and the session stays hot.
    private func scheduleDeactivate() {
        cancelPendingDeactivate()
        pendingDeactivate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if !self.synthesizer.isSpeaking {
                AudioPlaybackManager.shared.deactivate()
            }
        }
    }

    private func cancelPendingDeactivate() {
        pendingDeactivate?.cancel()
        pendingDeactivate = nil
    }
}

extension LocalTTS: @preconcurrency AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleDeactivate() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleDeactivate() }
    }
}
