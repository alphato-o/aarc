import Foundation
import Observation
import UIKit

/// Observable music state for the in-run UI. Polls Spotify every few
/// seconds while a run is active, caches audio-features per track so
/// the kinetic visualizer can modulate its bars to the actual BPM, and
/// exposes thin async wrappers for the playback controls.
///
/// Only runs while ActiveRunView is visible. The polling task is
/// started in `start()` and torn down in `stop()` so we don't burn
/// Spotify rate limit when the runner is staring at the home screen.
@Observable
@MainActor
final class NowPlayingStore {
    static let shared = NowPlayingStore()

    /// Current track if Spotify is connected and playing. nil otherwise.
    private(set) var track: SpotifyClient.Track?
    /// BPM for the current track, looked up via /audio-features. nil if
    /// not yet fetched or unavailable.
    private(set) var tempoBPM: Double?
    /// Locally-decoded cover art so the UI doesn't refetch on every redraw.
    private(set) var coverArt: UIImage?
    /// Set after the user taps a control + the request returned 4xx — UI
    /// surfaces this once and clears on the next successful poll.
    private(set) var lastControlError: String?

    private(set) var isRunning: Bool = false
    private var pollTask: Task<Void, Never>?
    private var featuresByTrackId: [String: SpotifyClient.AudioFeatures] = [:]

    /// Poll cadence while running. 4s keeps the progress bar tolerably
    /// fresh without spamming Spotify (rate limit is ~180/min for
    /// /currently-playing).
    private let pollInterval: TimeInterval = 4

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        track = nil
        tempoBPM = nil
        coverArt = nil
        lastControlError = nil
    }

    /// One-off refresh, called once on start and on every poll tick.
    func refresh() async {
        let result = await SpotifyClient.shared.currentlyPlaying()
        switch result {
        case .track(let t):
            let trackChanged = (track?.id != t.id)
            track = t
            if trackChanged {
                tempoBPM = nil
                coverArt = nil
                if let id = t.id {
                    await fetchFeaturesIfNeeded(trackId: id)
                }
                if let url = t.albumImageURL {
                    await loadCover(url: url)
                }
            } else if coverArt == nil, let url = t.albumImageURL {
                // Same track, but cover never loaded (initial start while
                // a track was already playing). Pull it now.
                await loadCover(url: url)
            }
        case .nothingPlaying, .notConnected:
            track = nil
            tempoBPM = nil
            coverArt = nil
        }
    }

    // MARK: - Playback control

    func togglePlayPause() async {
        guard let t = track else { return }
        do {
            if t.isPlaying {
                try await SpotifyClient.shared.pause()
            } else {
                try await SpotifyClient.shared.resume()
            }
            lastControlError = nil
            // Optimistic local flip so the icon swaps immediately; the
            // next poll will resync from server truth.
            track = SpotifyClient.Track(
                id: t.id, title: t.title, artist: t.artist, album: t.album,
                albumImageURL: t.albumImageURL, isPlaying: !t.isPlaying,
                progressMs: t.progressMs, durationMs: t.durationMs
            )
        } catch {
            lastControlError = error.localizedDescription
        }
    }

    func next() async {
        do {
            try await SpotifyClient.shared.next()
            lastControlError = nil
            // Force a refresh so the new track lands fast.
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        } catch {
            lastControlError = error.localizedDescription
        }
    }

    func previous() async {
        do {
            try await SpotifyClient.shared.previous()
            lastControlError = nil
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        } catch {
            lastControlError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func fetchFeaturesIfNeeded(trackId: String) async {
        if let cached = featuresByTrackId[trackId] {
            tempoBPM = cached.tempo
            return
        }
        guard let features = await SpotifyClient.shared.audioFeatures(trackId: trackId) else {
            tempoBPM = nil
            return
        }
        featuresByTrackId[trackId] = features
        tempoBPM = features.tempo
    }

    private func loadCover(url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                coverArt = img
            }
        } catch {
            // Not fatal — UI shows a placeholder.
        }
    }
}
