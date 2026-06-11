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

    /// Primary ElevenLabs voice — the Roast Coach (Ricky). Default for
    /// any line that doesn't specify a voice.
    static let voiceId: String = "lKMAeQD7Brvj7QCWByqK"

    /// Jessica — the second voice (seductive, explicit, conflicted British
    /// woman who reacts to Ricky). Passed explicitly on her lines.
    static let jessicaVoiceId: String = "jP5jSWhfXz3nfQENMtf4"

    /// Cumulative bytes pulled from the proxy this session — diagnostic.
    private(set) var bytesFetchedThisSession: Int = 0
    /// Whether we used the cache instead of fetching, last call.
    private(set) var lastWasCacheHit: Bool = false
    /// Last upstream error string, if the most recent attempt fell back.
    private(set) var lastError: String?

    // MARK: - Live diagnostics (observed by Coach Playground)

    /// What the TTS engine is doing right now.
    enum Activity: Equatable {
        case idle
        case synthesizing(chars: Int)   // waiting on ElevenLabs v3
        case playing(remote: Bool)      // remote == false → Apple fallback
    }
    private(set) var activity: Activity = .idle
    /// When the current ElevenLabs synth started — for a live elapsed readout.
    private(set) var synthStartedAt: Date?
    /// What actually voiced the last line: "ElevenLabs" or "Apple (fallback)".
    private(set) var lastBackend: String?
    /// Fetch latency of the last non-cached synth, in milliseconds.
    private(set) var lastLatencyMs: Int?
    /// Character count of the last line — latency on v3 scales with this.
    private(set) var lastChars: Int?

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
    func play(text: String, voiceId: String = RemoteTTS.voiceId, onAudioStart: (@MainActor @Sendable () -> Void)? = nil) async {
        guard !text.isEmpty else { return }
        lastChars = text.count
        defer { activity = .idle; synthStartedAt = nil }

        let key = AudioCache.key(voiceId: voiceId, text: text)
        let url: URL
        if let cached = await AudioCache.shared.url(forKey: key) {
            url = cached
            lastWasCacheHit = true
            lastLatencyMs = 0
            lastError = nil
        } else {
            activity = .synthesizing(chars: text.count)
            synthStartedAt = Date()
            let started = Date()
            do {
                let data = try await fetchAudioWithOneRetry(text: text, voiceId: voiceId)
                lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
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
                // Most common non-cancel case: an ElevenLabs v3 synth that
                // ran past the timeout (long lines take ~25s). Surface it
                // and fall back to Apple so the runner is never silent.
                lastError = error.localizedDescription
                lastBackend = "Apple (fallback)"
                activity = .playing(remote: false)
                RunEventLog.shared.record("tts.fallback", String(text.prefix(80)),
                                          data: ["reason": error.localizedDescription, "backend": "local"])
                await LocalTTS.shared.play(text: text, onAudioStart: onAudioStart)
                return
            }
        }

        activity = .playing(remote: true)
        lastBackend = "ElevenLabs"
        // Voice archive + replay: record what's about to be heard, keyed
        // to the cached MP3 so the run log can pin + replay the audio.
        RunEventLog.shared.recordSpeech(
            text: text,
            voiceId: voiceId,
            source: lastWasCacheHit ? "cache" : "fetch",
            cacheKey: key
        )
        RunEventLog.shared.record("tts.play", String(text.prefix(80)),
                                  data: ["ms": String(lastLatencyMs ?? 0), "cached": String(lastWasCacheHit)])
        AudioPlaybackManager.shared.activate()
        // While the queue is in sustained mode (phone-only treadmill),
        // the session is .mixWithOthers WITHOUT ducking. Flip on the
        // .duckOthers option transiently so music drops while the
        // coach speaks, then back. No-op otherwise. defer guarantees
        // we clear the duck on every exit path — engine success,
        // engine fail + player success, both fail + LocalTTS, or task
        // cancellation.
        AudioPlaybackManager.shared.beginTransientDuck()
        defer { AudioPlaybackManager.shared.endTransientDuck() }

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
            lastBackend = "Apple (fallback)"
            activity = .playing(remote: false)
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
    func prefetch(_ text: String, voiceId: String = RemoteTTS.voiceId) async {
        guard !text.isEmpty else { return }
        let key = AudioCache.key(voiceId: voiceId, text: text)
        if await AudioCache.shared.url(forKey: key) != nil { return }
        do {
            let data = try await fetchAudio(text: text, voiceId: voiceId)
            bytesFetchedThisSession += data.count
            _ = try await AudioCache.shared.store(data: data, forKey: key)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Like `prefetch`, but returns the measured latency and whether the
    /// line was already cached — so the Coach Playground can show a live
    /// progress bar of warming an entire run's worth of voice lines (and
    /// the real ElevenLabs cost of doing so). Updates `activity` too so the
    /// status panel reflects it.
    func warmMeasured(_ text: String, voiceId: String = RemoteTTS.voiceId) async -> (ms: Int, cached: Bool) {
        guard !text.isEmpty else { return (0, true) }
        let key = AudioCache.key(voiceId: voiceId, text: text)
        if await AudioCache.shared.url(forKey: key) != nil { return (0, true) }
        activity = .synthesizing(chars: text.count)
        synthStartedAt = Date()
        defer { activity = .idle; synthStartedAt = nil }
        let started = Date()
        do {
            let data = try await fetchAudio(text: text, voiceId: voiceId)
            bytesFetchedThisSession += data.count
            _ = try await AudioCache.shared.store(data: data, forKey: key)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        lastLatencyMs = ms
        lastChars = text.count
        return (ms, false)
    }

    // MARK: - Network

    /// `fetchAudio` plus exactly ONE retry, used by the live `play` path.
    /// Cellular runs drop requests (timed out / connection lost) often
    /// enough that falling straight to the Apple voice on the first
    /// failure was wasting recoverable lines. One 1.5s-spaced retry
    /// recovers most transient drops without stalling the queue long.
    ///
    /// Bookkeeping: the caller's `activity = .synthesizing` stays in
    /// effect across the retry; we re-stamp `synthStartedAt` so the
    /// live elapsed readout reflects the attempt in flight, not the
    /// failed one. `Task.sleep` throws on cancellation, which propagates
    /// to the caller's catch where the `Task.isCancelled` check returns
    /// without falling back — preserving the stop-mid-fetch discipline.
    private func fetchAudioWithOneRetry(text: String, voiceId: String) async throws -> Data {
        do {
            return try await fetchAudio(text: text, voiceId: voiceId)
        } catch {
            if Task.isCancelled { throw error }
            log.error("[tts] retrying after: \(error.localizedDescription, privacy: .public)")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            synthStartedAt = Date()
            return try await fetchAudio(text: text, voiceId: voiceId)
        }
    }

    private func fetchAudio(text: String, voiceId: String = RemoteTTS.voiceId) async throws -> Data {
        let url = Config.apiBaseURL.appendingPathComponent("tts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // eleven_v3 latency scales with length: ~3s for a short coach line,
        // but ~25s for one of Jessica's long passages. 15s was cutting the
        // long ones off and dumping them to Apple TTS — 60s gives v3 room
        // to finish even at the long end.
        request.timeoutInterval = 60
        let body: [String: Any] = ["text": text, "voiceId": voiceId]
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
