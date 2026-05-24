import Foundation
import AVFoundation
import OSLog

/// Plays a continuous silent audio buffer for the duration of a
/// phone-only treadmill run, so the app actually qualifies for the
/// `.audio` UIBackgroundMode it declared in Info.plist.
///
/// **Why this exists.** Phone-only treadmill mode has no other
/// background-mode coverage — outdoor runs get `.location` via
/// `CLLocationManager`, but treadmill skips GPS. Without continuously
/// flowing audio, iOS suspends the app within seconds of losing
/// foreground and the pedometer's update callback stops firing. Just
/// "activating" the audio session isn't enough — iOS only grants
/// `.audio` background grace while audio data is actively produced.
///
/// **How it stays inaudible.** A dedicated `AVAudioEngine` mixes
/// silent PCM samples through a player node into the mixer's output
/// with `outputVolume = 0`. Even at full system volume there's
/// nothing in the buffer to hear. The engine is independent of
/// `RemoteTTS`'s engine — both share the system audio session
/// without interfering, and TTS playback rides on top of the silent
/// loop without an audible artefact.
@MainActor
final class BackgroundAudioKeepalive {
    static let shared = BackgroundAudioKeepalive()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var configured = false
    private(set) var isRunning = false
    private let log = Logger(subsystem: "club.aarun.AARC", category: "BackgroundAudioKeepalive")

    private init() {}

    func start() {
        guard !isRunning else { return }
        do {
            try configureIfNeeded()
            if !engine.isRunning {
                try engine.start()
            }
            scheduleSilence()
            playerNode.play()
            isRunning = true
            log.info("Started — silent loop active, app retains .audio background grace")
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard isRunning else { return }
        playerNode.stop()
        engine.stop()
        isRunning = false
        log.info("Stopped — background grace released")
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        engine.attach(playerNode)
        // format: nil lets the engine pick its natural output format —
        // matches whatever silent buffer we schedule via the same
        // format snapshot below.
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        // Silent through hardware no matter what. We DON'T touch the
        // AVAudioSession volume; that belongs to the user. We just
        // zero our own mixer so the contribution to the output mix
        // is digital silence.
        engine.mainMixerNode.outputVolume = 0
        configured = true
    }

    private func scheduleSilence() {
        let format = playerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        // 1-second silent buffer, looped — gives iOS a steady stream
        // of zero-amplitude samples to satisfy the "audio is actively
        // playing" requirement for background grace.
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        // PCM buffers initialise to zero, which is silence. No need
        // to write any samples explicitly.
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }
}
