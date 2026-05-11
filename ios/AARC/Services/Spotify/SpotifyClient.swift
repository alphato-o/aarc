import Foundation
import OSLog

/// Spotify Web API client. Phase 1 only needs "currently playing"; the
/// /v1/me/player/currently-playing endpoint is rate-limit-friendly and
/// gives us track + artist + album for whatever the user is playing on
/// any device signed into the same account.
struct SpotifyClient {
    static let shared = SpotifyClient()
    private let base = URL(string: "https://api.spotify.com/v1")!
    private let log = Logger(subsystem: "club.aarun.AARC", category: "SpotifyClient")

    struct Track: Sendable {
        let title: String
        let artist: String
        let album: String?
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
            return .track(Track(
                title: item.name,
                artist: artist.isEmpty ? "Unknown artist" : artist,
                album: item.album?.name,
                isPlaying: wire.is_playing ?? true,
                progressMs: wire.progress_ms,
                durationMs: item.duration_ms
            ))
        } catch {
            log.error("Spotify currentlyPlaying error: \(error.localizedDescription, privacy: .public)")
            return .nothingPlaying
        }
    }

    // MARK: - Wire types

    private struct Wire: Decodable {
        let is_playing: Bool?
        let progress_ms: Int?
        let item: Item?
    }

    private struct Item: Decodable {
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
    }
}
