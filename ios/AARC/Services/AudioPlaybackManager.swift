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
    /// BASELINE IS NON-DUCKING. Ducking is now purely transient — applied
    /// the instant a voice line starts and removed the instant it ends (see
    /// begin/endTransientDuck), in EVERY mode. The old baseline `.duckOthers`
    /// kept the music suppressed for as long as the session stayed active —
    /// which on a watch-mirrored run is the whole inter-line gap, so the
    /// runner heard ~35s of squashed music between two ~10s voice lines. Now
    /// the music sits at full volume except for the few seconds a voice is
    /// actually speaking over it.
    ///
    /// Note: `mode: .default` is deliberate — NOT `.spokenAudio`. The
    /// .spokenAudio mode runs the audio through Apple's
    /// "speech-intelligibility" signal chain (a soft compressor + EQ) that
    /// squashes peaks, so hot ElevenLabs renders perceptibly drop in level.
    /// .default leaves the audio alone.
    private func configureCategory() {
        applyCategory(duck: false)
    }

    /// Last duck state we actually applied — skips a redundant setCategory
    /// when nothing changed. begin/endTransientDuck fire once per line; with
    /// the keepalive engine running, re-setting the same category options on
    /// a live session every line is needless churn (and a possible audible
    /// blip). nil = not yet applied.
    private var appliedDuck: Bool?

    private func applyCategory(duck: Bool) {
        guard appliedDuck != duck else { return }
        do {
            var opts: AVAudioSession.CategoryOptions = [.mixWithOthers]
            if duck { opts.insert(.duckOthers) }
            try session.setCategory(.playback, mode: .default, options: opts)
            appliedDuck = duck
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
        applyCategory(duck: false)   // baseline is non-ducking
        deactivate()
    }

    /// Duck the music NOW — called the instant a voice line is about to be
    /// audible. Applies in every mode (not just sustained): the baseline is
    /// non-ducking, so this is the ONLY thing that lowers the music, and it's
    /// removed the moment the line ends.
    func beginTransientDuck() {
        applyCategory(duck: true)
    }

    /// Restore the music to full volume — called the instant a voice line
    /// finishes, so the runner hears the song again immediately rather than
    /// through the rest of the inter-line gap.
    func endTransientDuck() {
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
