import Foundation
import AVFoundation
import Observation

/// Cloud TTS via the Worker proxy → ElevenLabs. Caches per (voiceId, text)
/// hash so repeated lines never pay a second time. Plays through
/// AVAudioPlayer, which sits inside the same AVAudioSession as Apple's
/// AVSpeechSynthesizer — Spotify ducking still works identically.
///
/// On any network or upstream failure the call falls back to LocalTTS
/// so the runner is never silent on race day if signal flakes.
///
/// Playback is now serialised by `VoiceFeedbackQueue`. The public entry
/// point is `play(text:)`, which fetches/decodes/plays and only returns
/// once the audio is fully finished — so the queue can advance cleanly.
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

    private var player: AVAudioPlayer?
    /// Continuation resumed when the current AVAudioPlayer finishes (or
    /// fails / is stopped). Owned by `play(text:)`.
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Speak a single line and return only once the audio is fully done
    /// playing (or has failed and fallen back to LocalTTS, which also
    /// awaits completion). Called by the queue's serial playback loop.
    func play(text: String) async {
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
                // Network / upstream failure → speak with the local
                // synthesizer so the runner isn't silent. Await completion
                // so the queue's serial loop stays serial.
                lastError = error.localizedDescription
                await LocalTTS.shared.play(text: text)
                return
            }
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            self.player = p
            p.prepareToPlay()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.playbackContinuation = cont
                p.play()
            }
        } catch {
            lastError = "AVAudioPlayer: \(error.localizedDescription)"
            await LocalTTS.shared.play(text: text)
        }
    }

    /// Stop the currently-playing audio immediately. Used by the queue
    /// when a higher-priority item preempts. Resumes any in-flight
    /// continuation so the awaiting playback loop unblocks.
    func stopAll() {
        player?.stop()
        player = nil
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume()
        }
    }

    /// Download + cache the audio for a line WITHOUT playing it. Used by
    /// RunOrchestrator to warm the cache during the prepare phase so the
    /// warmup at t=0 plays instantly. Best-effort; on failure the live
    /// `play(text:)` path will retry or fall back to LocalTTS.
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
            // Resume the awaiter. The queue (or caller) decides what to do
            // next; we don't touch the audio session here any more — the
            // queue owns activate/deactivate.
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
