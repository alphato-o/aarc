import Foundation
import Observation

/// In-run subtitle state surfaced to the UI. The voice queue notifies
/// this store every time a line starts and finishes playing; the
/// store keeps the "current line" visible during playback AND for a
/// short dwell window AFTER playback, so the runner has time to
/// react with the heart button.
///
/// Single source of truth for "what is currently on the subtitle bar".
@Observable
@MainActor
final class LiveSubtitleStore {
    static let shared = LiveSubtitleStore()

    /// Hold the subtitle on screen this long after the underlying TTS
    /// audio finishes. 6 seconds is enough time to read it (the line
    /// itself is usually under 250 chars / ~5s spoken) and tap heart
    /// without rushing. New lines that arrive during the dwell window
    /// replace the current line immediately.
    private let dwellSeconds: TimeInterval = 6

    struct Line: Identifiable, Equatable {
        let id: UUID
        let text: String
        let source: String
        let priority: VoicePriority
        let startedAt: Date
        var isPlaying: Bool
        /// Total seconds the bar should remain visible from `startedAt`,
        /// drives the thin "react window" progress bar at the bottom
        /// of the subtitle widget.
        let estimatedTotalDwell: TimeInterval
        var liked: Bool
    }

    private(set) var currentLine: Line?

    /// True iff the subtitle has been on-screen long enough that the
    /// dwell timer is running (i.e. audio finished, waiting for user
    /// to tap heart). UI uses this to drain the progress bar.
    var isInDwellWindow: Bool {
        guard let line = currentLine else { return false }
        return !line.isPlaying
    }

    private var clearTask: Task<Void, Never>?

    // MARK: - Voice queue callbacks

    func startedPlaying(_ item: VoiceItem) {
        clearTask?.cancel()
        let liked = LikedLinesStore.shared.isLiked(text: item.text)
        let estTotalDwell = Self.estimateSpeakingDuration(for: item.text) + dwellSeconds
        currentLine = Line(
            id: item.id,
            text: item.text,
            source: item.source,
            priority: item.priority,
            startedAt: .now,
            isPlaying: true,
            estimatedTotalDwell: estTotalDwell,
            liked: liked
        )
    }

    func finishedPlaying(_ item: VoiceItem) {
        // Only act if this is still the currently-displayed line.
        // If a higher-priority preemption already replaced it, the
        // dwell timer should be tied to the NEW line, not the old.
        guard currentLine?.id == item.id else { return }
        currentLine?.isPlaying = false
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self, itemId = item.id] in
            try? await Task.sleep(for: .seconds(self?.dwellSeconds ?? 6))
            guard let self else { return }
            if self.currentLine?.id == itemId {
                self.currentLine = nil
            }
        }
    }

    /// Wiped by VoiceFeedbackQueue.stopAll (end of run, mute, etc.) so
    /// nothing lingers after the user explicitly killed playback.
    func clear() {
        clearTask?.cancel()
        clearTask = nil
        currentLine = nil
    }

    // MARK: - Heart toggle

    /// Toggle the heart for the currently-displayed line. Updates the
    /// persistent LikedLinesStore + the local liked flag so the UI
    /// re-renders without a round-trip.
    func toggleLike() {
        guard let line = currentLine else { return }
        if line.liked {
            LikedLinesStore.shared.unlike(text: line.text)
        } else {
            LikedLinesStore.shared.like(
                text: line.text,
                source: line.source,
                personalityId: "roast_coach"
            )
        }
        currentLine?.liked.toggle()
    }

    // MARK: - Helpers

    /// Rough estimate of how long the line will take to speak so the
    /// UI's progress bar starts from a sensible total. Real audio
    /// duration is set by AVAudioPlayer (RemoteTTS) but we can't read
    /// it back from here without coupling the layers. ~12 chars/sec
    /// is a typical conversational pace for Roast Coach lines through
    /// ElevenLabs.
    private static func estimateSpeakingDuration(for text: String) -> TimeInterval {
        max(2, TimeInterval(text.count) / 12.0)
    }
}
