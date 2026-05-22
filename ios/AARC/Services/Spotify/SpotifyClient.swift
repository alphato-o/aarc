import Foundation
import OSLog

/// Spotify Web API client. Reads currently-playing for lyric-driven
/// commentary; also exposes playback transport (play / pause / next /
/// previous) for the in-run media panel and audio-features for the
/// kinetic visualizer's tempo modulation.
struct SpotifyClient {
    static let shared = SpotifyClient()
    private let base = URL(string: "https://api.spotify.com/v1")!
    private let log = Logger(subsystem: "club.aarun.AARC", category: "SpotifyClient")

    struct Track: Sendable {
        /// Spotify track ID. Needed to look up audio-features (tempo).
        let id: String?
        let title: String
        let artist: String
        let album: String?
        /// URL of an album cover image — picks a small one (~64-300px)
        /// so we're not pulling 600KB album art over LTE.
        let albumImageURL: URL?
        let isPlaying: Bool
        /// Current playback position within the track. Used to look up
        /// the line of synced lyrics being sung right now.
        let progressMs: Int?
        let durationMs: Int?
    }

    enum Result: Sendable {
        case track(Track)
        case nothingPlaying
        case notConnected
    }

    struct AudioFeatures: Sendable {
        let tempo: Double  // BPM
        let energy: Double  // 0.0 – 1.0
    }

    func currentlyPlaying() async -> Result {
        guard let token = await SpotifyAuth.shared.validAccessToken() else {
            return .notConnected
        }
        let url = base.appendingPathComponent("me/player/currently-playing")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .nothingPlaying }
            if http.statusCode == 204 || data.isEmpty {
                // No content == nothing playing right now.
                return .nothingPlaying
            }
            if http.statusCode == 401 {
                // Token may have just expired between the validity check
                // and the request. Don't loop — let the caller retry on
                // the next probe cycle.
                log.info("Spotify currentlyPlaying returned 401; will refresh on next attempt")
                return .notConnected
            }
            guard (200...299).contains(http.statusCode) else {
                log.error("Spotify currentlyPlaying HTTP \(http.statusCode, privacy: .public)")
                return .nothingPlaying
            }
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard let item = wire.item else { return .nothingPlaying }
            let artist = (item.artists.compactMap { $0.name }).joined(separator: ", ")
            // Smallest non-tiny image — Spotify returns descending sizes;
            // pick the second-smallest if available (~300px) which is
            // sharp enough on a phone without bloating the cache.
            let imageURL: URL? = {
                guard let images = item.album?.images, !images.isEmpty else { return nil }
                let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
                let pick = sorted.first(where: { ($0.width ?? 0) >= 200 }) ?? sorted.last
                return pick?.url.flatMap(URL.init(string:))
            }()
            return .track(Track(
                id: item.id,
                title: item.name,
                artist: artist.isEmpty ? "Unknown artist" : artist,
                album: item.album?.name,
                albumImageURL: imageURL,
                isPlaying: wire.is_playing ?? true,
                progressMs: wire.progress_ms,
                durationMs: item.duration_ms
            ))
        } catch {
            log.error("Spotify currentlyPlaying error: \(error.localizedDescription, privacy: .public)")
            return .nothingPlaying
        }
    }

    /// Fetch tempo + energy for a track. Used by the in-run visualizer
    /// to modulate the bar animation with the music's BPM. Returns nil
    /// on any failure (including the rare case where Spotify hasn't
    /// computed features for a freshly-released track).
    func audioFeatures(trackId: String) async -> AudioFeatures? {
        guard let token = await SpotifyAuth.shared.validAccessToken() else { return nil }
        let url = base.appendingPathComponent("audio-features/\(trackId)")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 6
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let wire = try JSONDecoder().decode(FeaturesWire.self, from: data)
            return AudioFeatures(tempo: wire.tempo, energy: wire.energy)
        } catch {
            return nil
        }
    }

    // MARK: - Playback control
    //
    // Spotify Web API playback control needs an active device. If no
    // device is available, the API returns 404 NO_ACTIVE_DEVICE. The
    // app responds by surfacing a "Open Spotify on your phone to
    // control playback" hint via the thrown error.

    enum ControlError: Error, LocalizedError {
        case notConnected
        case noActiveDevice
        case premiumRequired
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Spotify not connected."
            case .noActiveDevice: return "No active Spotify device. Open Spotify on your phone first."
            case .premiumRequired: return "Spotify Premium is required for playback control."
            case .http(let code): return "Spotify HTTP \(code)."
            }
        }
    }

    func resume() async throws { try await transport(method: "PUT", path: "me/player/play") }
    func pause() async throws { try await transport(method: "PUT", path: "me/player/pause") }
    func next() async throws { try await transport(method: "POST", path: "me/player/next") }
    func previous() async throws { try await transport(method: "POST", path: "me/player/previous") }

    private func transport(method: String, path: String) async throws {
        guard let token = await SpotifyAuth.shared.validAccessToken() else {
            throw ControlError.notConnected
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "content-length")
        req.timeoutInterval = 6
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ControlError.http(0) }
        switch http.statusCode {
        case 200, 202, 204: return
        case 401: throw ControlError.notConnected
        case 403: throw ControlError.premiumRequired
        case 404: throw ControlError.noActiveDevice
        default: throw ControlError.http(http.statusCode)
        }
    }

    // MARK: - Wire types

    private struct Wire: Decodable {
        let is_playing: Bool?
        let progress_ms: Int?
        let item: Item?
    }

    private struct Item: Decodable {
        let id: String?
        let name: String
        let artists: [Artist]
        let album: Album?
        let duration_ms: Int?
    }

    private struct Artist: Decodable {
        let name: String?
    }

    private struct Album: Decodable {
        let name: String?
        let images: [Image]?
    }

    private struct Image: Decodable {
        let url: String?
        let width: Int?
        let height: Int?
    }

    private struct FeaturesWire: Decodable {
        let tempo: Double
        let energy: Double
    }
}
