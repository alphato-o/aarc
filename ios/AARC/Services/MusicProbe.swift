import Foundation
import AVFoundation

/// Best-effort detector for "what is the runner listening to right now?"
///
/// Order of attempts:
/// 1. Spotify Web API `currently-playing` — gives full track metadata.
/// 2. Fallback to `AVAudioSession.isOtherAudioPlaying` — confirms that
///    *something* is playing without specifics, useful when the user
///    hasn't connected Spotify yet or is using a different player.
struct MusicProbe {
    static let shared = MusicProbe()

    struct Track: Sendable {
        let title: String
        let artist: String
        let album: String?
        let isPlaying: Bool
        let progressMs: Int?
        let durationMs: Int?
    }

    enum State: Sendable {
        /// Got specific track metadata from Spotify.
        case track(Track)
        /// Audio is playing but we don't know what (Spotify not connected,
        /// or no current track in /currently-playing yet).
        case unknownAudio
        /// Silence.
        case silent
    }

    func current() async -> State {
        let spotify = await SpotifyClient.shared.currentlyPlaying()
        switch spotify {
        case .track(let t):
            return .track(Track(
                title: t.title,
                artist: t.artist,
                album: t.album,
                isPlaying: t.isPlaying,
                progressMs: t.progressMs,
                durationMs: t.durationMs
            ))
        case .nothingPlaying, .notConnected:
            // Fall through to the system probe.
            break
        }

        // System probe: AVAudioSession can tell us if some other app
        // currently holds the audio focus / is playing.
        let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
        return other ? .unknownAudio : .silent
    }
}
