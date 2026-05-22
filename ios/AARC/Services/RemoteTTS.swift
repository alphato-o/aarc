import Foundation
import AVFoundation
import Observation
import OSLog

/// Cloud TTS via the Worker proxy → ElevenLabs. Caches per (voiceId, text)
/// hash so repeated lines never pay a second time.
///
/// **Playback path — amplified.** Audio is fed through an AVAudioEngine
/// graph with `mainMixerNode.outputVolume = 1.4` (~+3 dB). This lifts
/// the coach voice cleanly above the ducked-music-plus-ambient floor
/// that the runner is competing with on the treadmill / outdoors. The
/// engine stays warm across lines so per-utterance latency is small.
/// If the engine fails to start (rare — usually an audio-route change
/// mid-session), we fall back to a regular AVAudioPlayer at unity gain
/// so the runner is never silent. If THAT also fails we fall back to
/// LocalTTS.
///
/// **Cancellation discipline.** Every catch and every await checks
/// `Task.isCancelled` before falling through to the next layer. When
/// the queue is stopped (run ended, mute, audio interruption), nothing
/// downstream — Apple voice, audio session reactivation, anything —
/// should start as a result of an in-flight error.
@MainActor
@Observable
final class RemoteTTS: NSObject {
    static let shared = RemoteTTS()

    /// Hardcoded ElevenLabs voice. We picked one and we're sticking with
    /// it; no user-facing voice picker.
    static let voiceId: String = "lKMAeQD7Brvj7QCWByqK"

    /// Cumulative bytes pulled from the proxy this session — diagnostic.
    private(set) var bytesFetchedThisSession: Int = 0
    /// Whether we used the cache instead of fetching, last call.
    private(set) var lastWasCacheHit: Bool = false
    /// Last upstream error string, if the most recent attempt fell back.
    private(set) var lastError: String?

    // MARK: - Amplified engine path

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Output-mixer gain above unity. 1.4 ≈ +3 dB — perceptibly louder
    /// without significant clipping on already-hot ElevenLabs renders.
    /// Bump this up to ~1.6 if the runner still finds it too quiet;
    /// past ~1.8 audible clipping kicks in on louder syllables.
    private let amplifyGain: Float = 1.4
    private var engineConfigured: Bool = false

    // MARK: - Fallback AVAudioPlayer path

    /// Used only when the AVAudioEngine path fails to start. Plays at
    /// unity gain; quieter than the engine path but safer.
    private var fallbackPlayer: AVAudioPlayer?

    /// Continuation resumed when the current playback finishes (whether
    /// via natural end, preemption, or queue.stopAll). Owned by `play`.
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    private let log = Logger(subsystem: "club.aarun.AARC", category: "RemoteTTS")

    override init() {
        super.init()
        // Reset the audio engine when iOS hands us a configuration
        // change (route change, AirPods swap, etc.). Without this the
        // engine can silently stop producing audio after a route swap.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engineConfigured = false
            }
        }
    }

    /// Speak a single line and return only once the audio is fully done
    /// playing (or has fallen through every fallback). Called by the
    /// queue's serial playback loop.
    ///
    /// `onAudioStart` (optional) fires once when audio actually starts
    /// playing — engine `play()` returns, AVAudioPlayer `play()` returns,
    /// or LocalTTS's didStart delegate fires. Failed paths don't fire
    /// it. Used by the queue to surface the subtitle at the moment
    /// the runner hears the first syllable, not at the start of the
    /// fetch.
    func play(text: String, onAudioStart: (@MainActor @Sendable () -> Void)? = nil) async {
        guard !text.isEmpty else { return }

        let key = AudioCache.key(voiceId: Self.voiceId, text: text)
        let url: URL
        if let cached = await AudioCache.shared.url(forKey: key) {
            url = cached
            lastWasCacheHit = true
            lastError = nil
        } else {
            do {
                let data = try await fetchAudio(text: text)
                bytesFetchedThisSession += data.count
                url = try await AudioCache.shared.store(data: data, forKey: key)
                lastWasCacheHit = false
                lastError = nil
            } catch {
                // CRITICAL: if the run was stopped mid-fetch, URLSession
                // throws a cancellation error here. Falling through to
                // LocalTTS would speak the line via Apple's voice AFTER
                // the user explicitly killed the voice pipeline — which
                // is exactly the bug we saw on the treadmill End tap.
                if Task.isCancelled { return }
                lastError = error.localizedDescription
                await LocalTTS.shared.play(text: text, onAudioStart: onAudioStart)
                return
            }
        }

        AudioPlaybackManager.shared.activate()

        // Primary path: AVAudioEngine with amplified mixer.
        do {
            try await playViaEngine(url: url, onStart: onAudioStart)
            return
        } catch {
            if Task.isCancelled { return }
            log.error("Engine path failed: \(error.localizedDescription, privacy: .public). Falling back to AVAudioPlayer.")
        }

        // Fallback path: AVAudioPlayer at unity gain. Slightly quieter
        // but more compatible across odd audio routes.
        do {
            try await playViaAVAudioPlayer(url: url, onStart: onAudioStart)
            return
        } catch {
            if Task.isCancelled { return }
            lastError = "AVAudioPlayer: \(error.localizedDescription)"
            await LocalTTS.shared.play(text: text, onAudioStart: onAudioStart)
        }
    }

    // MARK: - Engine path

    private func playViaEngine(url: URL, onStart: (@MainActor @Sendable () -> Void)?) async throws {
        let file = try AVAudioFile(forReading: url)
        try ensureEngineStarted()
        if playerNode.isPlaying { playerNode.stop() }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.playbackContinuation = cont
            playerNode.scheduleFile(
                file,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let cont = self.playbackContinuation {
                        self.playbackContinuation = nil
                        cont.resume()
                    }
                }
            }
            playerNode.play()
            // Audio is producing samples within ~10ms of .play() — for
            // user perception this is the "start of speaking" moment.
            onStart?()
        }
    }

    private func ensureEngineStarted() throws {
        if !engineConfigured {
            // Detach an attached node before attaching again to avoid
            // duplicate attachments after a configuration change.
            if engine.attachedNodes.contains(playerNode) {
                engine.detach(playerNode)
            }
            engine.attach(playerNode)
            // format: nil → AVAudioEngine derives the format from the
            // playerNode's natural output, which matches whatever file
            // we schedule next (engine resamples internally if needed).
            engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = amplifyGain
            engineConfigured = true
        }
        if !engine.isRunning {
            try engine.start()
        }
    }

    // MARK: - AVAudioPlayer fallback path

    private func playViaAVAudioPlayer(url: URL, onStart: (@MainActor @Sendable () -> Void)?) async throws {
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.volume = 1.0
        self.fallbackPlayer = p
        p.prepareToPlay()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.playbackContinuation = cont
            p.play()
            // Same reasoning as the engine path — audio starts within
            // a frame or two of .play().
            onStart?()
        }
    }

    // MARK: - Stop

    /// Stop the currently-playing audio immediately. Used by the queue
    /// when a higher-priority item preempts OR when the run ends.
    /// Resumes any in-flight continuation so the awaiting playback loop
    /// unblocks. Doesn't tear down the engine — keeping it warm cuts
    /// the first-syllable latency on the next line.
    func stopAll() {
        if playerNode.isPlaying { playerNode.stop() }
        fallbackPlayer?.stop()
        fallbackPlayer = nil
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Prefetch

    /// Download + cache the audio for a line WITHOUT playing it. Used by
    /// RunOrchestrator to warm the cache during the prepare phase so the
    /// warmup at t=0 plays instantly. Best-effort; on failure the live
    /// `play(text:)` path will retry or fall back.
    func prefetch(_ text: String) async {
        guard !text.isEmpty else { return }
        let key = AudioCache.key(voiceId: Self.voiceId, text: text)
        if await AudioCache.shared.url(forKey: key) != nil { return }
        do {
            let data = try await fetchAudio(text: text)
            bytesFetchedThisSession += data.count
            _ = try await AudioCache.shared.store(data: data, forKey: key)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Network

    private func fetchAudio(text: String) async throws -> Data {
        let url = Config.apiBaseURL.appendingPathComponent("tts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        let body: [String: Any] = ["text": text, "voiceId": Self.voiceId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteTTSError.transport("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw RemoteTTSError.httpStatus(http.statusCode, body: bodyText.prefix(300).description)
        }
        return data
    }
}

extension RemoteTTS: @preconcurrency AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if let cont = self.playbackContinuation {
                self.playbackContinuation = nil
                cont.resume()
            }
        }
    }
}

enum RemoteTTSError: Error, LocalizedError {
    case transport(String)
    case httpStatus(Int, body: String)

    var errorDescription: String? {
        switch self {
        case .transport(let m): return "Network error: \(m)"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
