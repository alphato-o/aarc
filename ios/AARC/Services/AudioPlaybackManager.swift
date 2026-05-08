import Foundation
import AVFoundation
import Observation

/// Owns the iPhone's `AVAudioSession`. Categories the session for spoken
/// audio that mixes with and ducks other audio (Spotify, Apple Music,
/// Podcasts, Audible). Tracks active state, handles phone-call
/// interruptions, and exposes a "mute companion" toggle.
///
/// The actual speaking is done by `LocalTTS`; this class is the audio
/// session contract underneath.
@Observable
@MainActor
final class AudioPlaybackManager {
    static let shared = AudioPlaybackManager()

    private(set) var isSessionActive: Bool = false
    /// User-facing toggle. When true, all enqueued utterances are dropped
    /// at speak time and any in-flight utterance is stopped.
    var isMuted: Bool = false {
        didSet {
            if isMuted {
                Speaker.shared.stopAll()
            }
        }
    }

    private let session = AVAudioSession.sharedInstance()

    private init() {
        configureCategory()
        registerInterruptionObserver()
    }

    /// One-time category configuration. Idempotent.
    private func configureCategory() {
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers]
            )
        } catch {
            // Category set fails very rarely; log via os_log later if it
            // becomes an actual concern.
        }
    }

    /// Activates the audio session so the next utterance ducks other
    /// audio. Cheap if already active.
    func activate() {
        guard !isSessionActive else { return }
        do {
            try session.setActive(true, options: [])
            isSessionActive = true
        } catch {
            // Activation can fail if a phone call is up. We retry on the
            // next speak; nothing else to do here.
        }
    }

    /// Deactivates the session and signals other apps to restore their
    /// audio. Idempotent. Call once the synthesizer queue is empty.
    func deactivate() {
        guard isSessionActive else { return }
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            isSessionActive = false
        } catch {
            // Some iOS versions throw if the session was already torn
            // down by an interruption. Treat as success.
            isSessionActive = false
        }
    }

    // MARK: - Interruption handling

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Pull the Sendable bits out of the notification before the
            // actor hop — Notification itself isn't Sendable.
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: raw)
            }
        }
    }

    private func handleInterruption(rawType: UInt?) {
        guard let raw = rawType,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // Phone call / Siri started — drop in-flight utterance.
            Speaker.shared.stopAll()
            isSessionActive = false

        case .ended:
            // Don't auto-resume in V1. Next user-triggered utterance
            // will reactivate the session cleanly.
            break

        @unknown default:
            break
        }
    }
}
