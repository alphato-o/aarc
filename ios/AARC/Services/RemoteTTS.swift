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
@MainActor
@Observable
final class RemoteTTS: NSObject {
    static let shared = RemoteTTS()

    /// Currently selected voice. Mutable; UI binds to it.
    var voice: ElevenLabsVoice = .danielBritish

    /// Cumulative bytes pulled from the proxy this session — diagnostic.
    private(set) var bytesFetchedThisSession: Int = 0
    /// Whether we used the cache instead of fetching, last call.
    private(set) var lastWasCacheHit: Bool = false

    private var player: AVAudioPlayer?

    /// Speak a single line. Asynchronous: first call for a (voice, text)
    /// pair waits on the network round-trip; subsequent calls play from
    /// the local cache.
    func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        guard !AudioPlaybackManager.shared.isMuted else { return }

        let key = AudioCache.key(voiceId: voice.id, text: text)
        let url: URL
        if let cached = await AudioCache.shared.url(forKey: key) {
            url = cached
            lastWasCacheHit = true
        } else {
            do {
                let data = try await fetchAudio(text: text)
                bytesFetchedThisSession += data.count
                url = try await AudioCache.shared.store(data: data, forKey: key)
                lastWasCacheHit = false
            } catch {
                // Network / upstream failure → speak with the local
                // synthesizer so the runner isn't silent.
                LocalTTS.shared.speak(text)
                return
            }
        }

        AudioPlaybackManager.shared.activate()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            self.player = p
            p.prepareToPlay()
            p.play()
        } catch {
            LocalTTS.shared.speak(text)
        }
    }

    func stopAll() {
        player?.stop()
        player = nil
    }

    private func fetchAudio(text: String) async throws -> Data {
        let url = Config.apiBaseURL.appendingPathComponent("tts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        let body: [String: Any] = ["text": text, "voiceId": voice.id]
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
        // Don't capture the AVAudioPlayer parameter into the Task — it's
        // not Sendable. We just need to know "speaking is over"; the
        // MainActor check on self.player handles the rest.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if self.player?.isPlaying != true {
                AudioPlaybackManager.shared.deactivate()
            }
        }
    }
}

// MARK: - Voice presets

/// A handful of ElevenLabs preset voices that ship on every account.
/// User can pick one in Settings → Audio. IDs are stable.
struct ElevenLabsVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let descriptor: String
    let accent: String

    static let danielBritish = ElevenLabsVoice(
        id: "onwK4e9ZLuTAKqWW03F9",
        name: "Daniel",
        descriptor: "deep, authoritative",
        accent: "British"
    )
    static let georgeBritish = ElevenLabsVoice(
        id: "JBFqnCBsd6RMkjVDRZzb",
        name: "George",
        descriptor: "warm, distinguished",
        accent: "British"
    )
    static let brianAmerican = ElevenLabsVoice(
        id: "nPczCjzI2devNBz1zQrb",
        name: "Brian",
        descriptor: "deep, narration",
        accent: "American"
    )
    static let antoniAmerican = ElevenLabsVoice(
        id: "ErXwobaYiN019PkySvjV",
        name: "Antoni",
        descriptor: "well-rounded",
        accent: "American"
    )
    static let charlieAustralian = ElevenLabsVoice(
        id: "IKne3meq5aSn9XLyUdCD",
        name: "Charlie",
        descriptor: "casual, friendly",
        accent: "Australian"
    )

    static let all: [ElevenLabsVoice] = [
        .danielBritish, .georgeBritish, .brianAmerican, .antoniAmerican, .charlieAustralian,
    ]
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
