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

    /// True audio duration + start of the line currently playing — lets the
    /// in-run karaoke roll the highlight against REAL playback time so its end
    /// aligns exactly with the audio (the char-count estimate ran ~30% long).
    /// nil when nothing is playing.
    private(set) var playbackDuration: TimeInterval?
    private(set) var playbackStartedAt: Date?
    func beginPlaybackTiming(duration: TimeInterval) {
        playbackDuration = duration > 0 ? duration : nil
        playbackStartedAt = .now
    }
    func clearPlaybackTiming() {
        playbackDuration = nil
        playbackStartedAt = nil
    }
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
            // Coalesced synth — shares any in-flight prewarm for this line.
            await ensureCached(text: text, voiceId: voiceId, key: key)
            // CRITICAL: if the run was stopped mid-fetch, bail before
            // playing — never speak via Apple AFTER the pipeline was killed
            // (the treadmill End-tap bug).
            if Task.isCancelled { return }
            if let cached = await AudioCache.shared.url(forKey: key) {
                url = cached
                lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                lastWasCacheHit = false
                lastError = nil
            } else {
                // Synth failed (e.g. an ElevenLabs v3 long-line timeout).
                // Fall back to Apple so the runner is never silent.
                lastBackend = "Apple (fallback)"
                activity = .playing(remote: false)
                RunEventLog.shared.record("tts.fallback", String(text.prefix(80)),
                                          data: ["reason": lastError ?? "synth failed", "backend": "local"])
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
        let dur = Double(file.length) / file.processingFormat.sampleRate
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
                    self.clearPlaybackTiming()
                    if let cont = self.playbackContinuation {
                        self.playbackContinuation = nil
                        cont.resume()
                    }
                }
            }
            playerNode.play()
            // Audio is producing samples within ~10ms of .play() — for
            // user perception this is the "start of speaking" moment.
            self.beginPlaybackTiming(duration: dur)
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
            self.beginPlaybackTiming(duration: p.duration)
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
        clearPlaybackTiming()
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Prefetch

    /// In-flight synths keyed by cache key, so concurrent callers
    /// (background prewarm + the dequeue's pre-duck prefetch + a direct
    /// play) for the SAME line share ONE ElevenLabs request instead of each
    /// firing a full synth. Without this, a line that dequeues before its
    /// prewarm finishes paid for the same audio twice.
    private var inFlightSynths: [String: Task<Void, Never>] = [:]

    /// Ensure (voiceId, text) is in the cache, coalescing concurrent
    /// requests. Returns once cached, or once the shared synth attempt has
    /// finished (callers re-check the cache to distinguish success). Never
    /// throws; uses the one-retry fetch so a cellular blip doesn't drop it.
    private func ensureCached(text: String, voiceId: String, key: String) async {
        if await AudioCache.shared.url(forKey: key) != nil { return }
        if let existing = inFlightSynths[key] {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightSynths[key] = nil }
            do {
                let data = try await self.fetchAudioWithOneRetry(text: text, voiceId: voiceId)
                self.bytesFetchedThisSession += data.count
                _ = try await AudioCache.shared.store(data: data, forKey: key)
                self.lastError = nil
            } catch {
                if !Task.isCancelled { self.lastError = error.localizedDescription }
            }
        }
        inFlightSynths[key] = task
        await task.value
    }

    /// Download + cache the audio for a line WITHOUT playing it. Used to warm
    /// the cache ahead of a line's slot so it plays instantly. Best-effort;
    /// coalesced with any concurrent synth for the same line.
    func prefetch(_ text: String, voiceId: String = RemoteTTS.voiceId) async {
        guard !text.isEmpty else { return }
        let key = AudioCache.key(voiceId: voiceId, text: text)
        await ensureCached(text: text, voiceId: voiceId, key: key)
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

    /// If the active endpoint hasn't delivered the audio within this many
    /// seconds, the SAME request is raced against the other endpoint and
    /// whichever finishes first wins. Born from the 2026-06-12 23:57 run:
    /// the CN→Cloudflare route stayed pingable while audio transfers
    /// crawled to 259s — the CN2 GIA gateway was healthy the whole time
    /// and never got asked. A normal synth answers well under this, so
    /// the hedge fires only when the route is already in trouble.
    private static let hedgeAfterSeconds: UInt64 = 12

    private func fetchAudio(text: String, voiceId: String = RemoteTTS.voiceId) async throws -> Data {
        // Dev override: single attempt, no hedging.
        if let override = ProcessInfo.processInfo.environment["AARC_API_BASE_URL"],
           let url = URL(string: override) {
            return try await attemptFetch(text: text, voiceId: voiceId, baseURL: url, tag: "dev")
        }
        let primary = EndpointManager.shared.currentEndpoint
        guard let backup = EndpointManager.shared.alternate else {
            return try await attemptFetch(text: text, voiceId: voiceId, baseURL: primary.url, tag: primary.id)
        }
        return try await withThrowingTaskGroup(of: (String, Result<Data, Error>).self) { group in
            group.addTask {
                do { return (primary.id, .success(try await self.attemptFetch(
                    text: text, voiceId: voiceId, baseURL: primary.url, tag: primary.id))) }
                catch { return (primary.id, .failure(error)) }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: Self.hedgeAfterSeconds * 1_000_000_000)
                    return (backup.id, .success(try await self.attemptFetch(
                        text: text, voiceId: voiceId, baseURL: backup.url, tag: backup.id)))
                } catch { return (backup.id, .failure(error)) }
            }
            var lastError: Error?
            while let (id, result) = try await group.next() {
                switch result {
                case .success(let data):
                    group.cancelAll()
                    await MainActor.run {
                        EndpointManager.shared.reportOutcome(endpointId: id, ok: true)
                        if id == backup.id {
                            // The hedge won: the primary was too slow to
                            // matter. Slow IS the failure mode here.
                            EndpointManager.shared.reportOutcome(
                                endpointId: primary.id, ok: false, reason: "lost tts hedge race")
                        }
                    }
                    return data
                case .failure(let error):
                    if !(error is CancellationError) {
                        lastError = error
                        await MainActor.run {
                            EndpointManager.shared.reportOutcome(
                                endpointId: id, ok: false, reason: error.localizedDescription)
                        }
                    }
                }
            }
            throw lastError ?? RemoteTTSError.transport("all endpoints failed")
        }
    }

    private func attemptFetch(text: String, voiceId: String, baseURL: URL, tag: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("tts")
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

        // Network inspector: surface the full 11Labs request lifecycle,
        // one entry per attempt so a hedge race shows as two rows.
        let net = NetworkActivityMonitor.shared.begin(
            service: "11Labs", label: text, chars: text.count)
        NetworkActivityMonitor.shared.awaiting(net)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                NetworkActivityMonitor.shared.fail(net, "non-HTTP response via \(tag)")
                throw RemoteTTSError.transport("non-HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
                NetworkActivityMonitor.shared.fail(net, "HTTP \(http.statusCode) via \(tag)")
                throw RemoteTTSError.httpStatus(http.statusCode, body: bodyText.prefix(300).description)
            }
            NetworkActivityMonitor.shared.finish(net, bytes: data.count, detail: "HTTP \(http.statusCode) via \(tag)")
            return data
        } catch {
            // Hedge loser (the other endpoint won the race) — cancellation
            // is expected and healthy, not a gateway failure. Record it
            // neutrally so the inspector doesn't flag the gateway as down.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                NetworkActivityMonitor.shared.cancel(net, "cancelled via \(tag)")
            } else {
                NetworkActivityMonitor.shared.fail(net, "\(error.localizedDescription) via \(tag)")
            }
            throw error
        }
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
