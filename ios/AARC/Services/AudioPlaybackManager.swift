import Foundation
import AVFoundation
import Observation
import os.log

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

    /// True when the runner has explicitly asked us to keep the
    /// session active across TTS gaps (phone-only treadmill run,
    /// where we have no other UIBackgroundMode keeping the app
    /// alive — the .audio mode applies only as long as the session
    /// stays active). When this is set, deactivate() becomes a no-op
    /// until clearSustained() is called.
    private(set) var sustainedActive: Bool = false

    /// One-time category configuration. Idempotent.
    ///
    /// Note: `mode: .default` is deliberate — NOT `.spokenAudio`. The
    /// .spokenAudio mode runs the audio through Apple's
    /// "speech-intelligibility" signal chain, which is essentially a
    /// soft compressor + EQ. That compressor squashes peaks, so on hot
    /// ElevenLabs renders (which are already mastered loud) the coach
    /// voice perceptibly drops in level. Switching to .default leaves
    /// the audio alone and the runner hears the file as it was
    /// rendered — which is what we want when we're competing with
    /// ducked-but-still-present background music + ambient noise.
    private func configureCategory() {
        applyCategory(duck: true)
    }

    private func applyCategory(duck: Bool) {
        do {
            var opts: AVAudioSession.CategoryOptions = [.mixWithOthers]
            if duck { opts.insert(.duckOthers) }
            try session.setCategory(.playback, mode: .default, options: opts)
        } catch {
            // Category set fails very rarely; log via os_log later if it
            // becomes an actual concern.
        }
    }

    /// Start sustained mode — used by phone-only treadmill runs to
    /// keep the AVAudioSession active across TTS gaps. While the
    /// session is active, the .audio UIBackgroundMode grants the app
    /// background grace, which keeps the pedometer's update callback
    /// firing even if the runner briefly backgrounds the app.
    ///
    /// We DROP .duckOthers while sustaining so background music isn't
    /// permanently turned down between coach lines. When a TTS line
    /// fires, the queue still has us flip momentarily to the ducking
    /// category via `beginTransientDuck()` and back via
    /// `endTransientDuck()`.
    func beginSustained() {
        guard !sustainedActive else { return }
        os_log("[audio] beginSustained — switching to .mixWithOthers (no duck) and activating session", log: OSLog(subsystem: "club.aarun.AARC", category: "Audio"), type: .info)
        applyCategory(duck: false)
        activate()
        sustainedActive = true
    }

    func endSustained() {
        guard sustainedActive else { return }
        os_log("[audio] endSustained", log: OSLog(subsystem: "club.aarun.AARC", category: "Audio"), type: .info)
        sustainedActive = false
        applyCategory(duck: true)
        deactivate()
    }

    func beginTransientDuck() {
        guard sustainedActive else { return }
        applyCategory(duck: true)
    }

    func endTransientDuck() {
        guard sustainedActive else { return }
        applyCategory(duck: false)
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
    ///
    /// No-op while sustained mode is on (phone-only treadmill needs
    /// the session to stay active across TTS gaps to keep the app
    /// alive via .audio UIBackgroundMode).
    func deactivate() {
        guard isSessionActive, !sustainedActive else { return }
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
