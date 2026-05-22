import Foundation
import Observation
import OSLog

/// Priority bucket for a queued voice item. Higher raw value = more important.
/// `.milestone` preempts `.banter` and `.coaching` mid-utterance. Equal-priority
/// items always queue FIFO; they never interrupt each other.
enum VoicePriority: Int, Comparable, Sendable {
    case banter = 0     // lyric / music riffs, persona banter
    case coaching = 1   // HR / pace observations, quiet-stretch motivation
    case milestone = 2  // km splits, halfway, near-finish, finish, scripted intro

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One unit of voice feedback. Created by ScriptEngine / ContextualCoach,
/// pushed through `Speaker`, consumed by `VoiceFeedbackQueue`.
struct VoiceItem: Identifiable, Sendable {
    let id: UUID
    let text: String
    let priority: VoicePriority
    /// Free-form diagnostic label ("script:km", "coach:hr_spike", "coach:music_riff").
    let source: String
    /// If non-nil, any item already in the queue (or currently playing) with the
    /// same key causes this one to be dropped at enqueue time. Used to suppress
    /// duplicate lyric riffs on the same song line.
    let dedupKey: String?
    let createdAt: Date
    /// If non-nil and `Date().timeIntervalSince(createdAt) > expiresAfter` at
    /// dequeue time, the item is dropped without playing. A 90s-late lyric joke
    /// belongs in the bin; a km split does not.
    let expiresAfter: TimeInterval?
    /// Override the global Speaker.preferRemoteVoice toggle for this item.
    /// Currently unused; reserved for future "force local for an offline-only
    /// safety line" needs.
    let preferRemoteVoiceOverride: Bool?

    init(
        id: UUID = UUID(),
        text: String,
        priority: VoicePriority,
        source: String,
        dedupKey: String? = nil,
        createdAt: Date = .now,
        expiresAfter: TimeInterval? = nil,
        preferRemoteVoiceOverride: Bool? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.source = source
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.expiresAfter = expiresAfter
        self.preferRemoteVoiceOverride = preferRemoteVoiceOverride
    }

    func isStale(at now: Date = .now) -> Bool {
        guard let expiresAfter else { return false }
        return now.timeIntervalSince(createdAt) > expiresAfter
    }
}

/// Central serialiser for all spoken feedback. Every line — scripted km
/// milestones, ContextualCoach reactive lines, lyric riffs — enters this queue
/// and plays in full before the next one starts. Higher-priority items can
/// preempt lower-priority ones; stale low-priority items are dropped silently
/// at dequeue time.
///
/// Concurrency: `@MainActor` so SwiftUI diagnostic UIs can observe state, and so
/// audio-session activate/deactivate (UIKit-thread-only on older iOS) is safe.
/// The actual TTS work happens in awaited async calls on `RemoteTTS` /
/// `LocalTTS`, both also `@MainActor`-bound.
@MainActor
@Observable
final class VoiceFeedbackQueue {
    static let shared = VoiceFeedbackQueue()

    // MARK: - Diagnostic state

    private(set) var currentlyPlaying: VoiceItem?
    private(set) var pending: [VoiceItem] = []
    /// Time the last item began playing (announcement included). UI uses this
    /// for "how long since last line" indicators.
    private(set) var lastDispatchedAt: Date?
    /// Total items that finished playing in the current run/session.
    private(set) var dispatched: Int = 0
    /// Items dropped because they were stale at dequeue time.
    private(set) var droppedStale: Int = 0
    /// Items dropped because their `dedupKey` was already represented.
    private(set) var droppedDuplicate: Int = 0
    /// Items interrupted by a higher-priority enqueue.
    private(set) var preempted: Int = 0

    // MARK: - Internal

    private let log = Logger(subsystem: "club.aarun.AARC", category: "VoiceQueue")
    private var playbackTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Add an item to the queue. May be played immediately (if nothing is
    /// playing), queued (if a same-or-higher-priority item is in flight),
    /// preempt the current item (if `item.priority > currentlyPlaying`), or
    /// silently dropped (dedup / mute).
    func enqueue(_ item: VoiceItem) {
        // Muted? Drop everything at enqueue time. Cheaper than queueing only
        // to no-op at play time, and keeps the queue length honest in UI.
        if AudioPlaybackManager.shared.isMuted {
            return
        }

        // Dedup against currently-playing and everything pending.
        if let key = item.dedupKey {
            if currentlyPlaying?.dedupKey == key
                || pending.contains(where: { $0.dedupKey == key }) {
                droppedDuplicate += 1
                log.info("VoiceQueue drop duplicate src=\(item.source, privacy: .public) key=\(key, privacy: .public)")
                return
            }
        }

        // Preemption: if nothing is playing, start now. If something lower-
        // priority is playing and this is higher, cut it off and start now.
        if currentlyPlaying == nil {
            startPlaying(item)
            return
        }
        if let cur = currentlyPlaying, item.priority > cur.priority {
            log.info("VoiceQueue preempt cur=\(cur.source, privacy: .public)(\(cur.priority.rawValue)) by new=\(item.source, privacy: .public)(\(item.priority.rawValue))")
            preempted += 1
            // Cancel the outstanding task BEFORE resuming its continuation,
            // so the awaited body sees Task.isCancelled == true and bails
            // without clobbering the new item.
            playbackTask?.cancel()
            playbackTask = nil
            Speaker.shared.stopActiveBackend()
            currentlyPlaying = nil
            // Push the new item to the front of the queue, then drain.
            pending.insert(item, at: 0)
            kickNext()
            return
        }

        // Otherwise queue it, sorted by priority desc, FIFO within priority.
        insertSorted(item)
        log.debug("VoiceQueue enqueue src=\(item.source, privacy: .public) pri=\(item.priority.rawValue) pending=\(self.pending.count)")
    }

    /// Stop everything immediately: cancel current playback, clear the queue,
    /// deactivate the audio session. Called by the mute toggle and at end of
    /// run.
    func stopAll() {
        playbackTask?.cancel()
        playbackTask = nil
        currentlyPlaying = nil
        pending.removeAll()
        Speaker.shared.stopActiveBackend()
        AudioPlaybackManager.shared.deactivate()
        // Wipe the subtitle so nothing lingers after an explicit
        // stop (end-run, mute, audio session interruption).
        LiveSubtitleStore.shared.clear()
    }

    /// Reset diagnostic counters at the start of a run.
    func resetStats() {
        dispatched = 0
        droppedStale = 0
        droppedDuplicate = 0
        preempted = 0
    }

    // MARK: - Internal playback loop

    private func insertSorted(_ item: VoiceItem) {
        // Find the first index whose priority is strictly lower than ours.
        // Insert there → equal-priority items keep arrival order.
        let idx = pending.firstIndex(where: { $0.priority < item.priority }) ?? pending.endIndex
        pending.insert(item, at: idx)
    }

    private func kickNext() {
        // Already playing? Existing task will advance on completion.
        guard currentlyPlaying == nil else { return }
        guard let next = popNextNonStale() else {
            // Queue empty — let session deactivate on its own grace timer.
            scheduleSessionDeactivate()
            return
        }
        startPlaying(next)
    }

    private func popNextNonStale() -> VoiceItem? {
        while let candidate = pending.first {
            pending.removeFirst()
            if candidate.isStale() {
                droppedStale += 1
                log.info("VoiceQueue drop stale src=\(candidate.source, privacy: .public)")
                continue
            }
            return candidate
        }
        return nil
    }

    private func startPlaying(_ item: VoiceItem) {
        currentlyPlaying = item
        lastDispatchedAt = .now
        deactivateTask?.cancel()
        // NOTE: do NOT activate the audio session here. Activation ducks
        // music immediately, and `playSync` will spend the next 100ms-2s
        // fetching+decoding the ElevenLabs audio — that gap was the source
        // of "music ducks, then long silence, then voice" after the queue
        // landed. RemoteTTS / LocalTTS now activate the session right
        // before the actual playback call so duck-in and audio-out are
        // back-to-back. The queue still owns deactivation when the queue
        // empties (so back-to-back items don't bounce the session).
        //
        // The subtitle store is notified *via the onAudioStart callback*
        // below — NOT here — so the in-run subtitle bar appears at the
        // moment the runner hears the first syllable rather than at the
        // moment of enqueue (which would spoil the roast during the
        // fetch window).

        playbackTask = Task { @MainActor [weak self] in
            await Speaker.shared.playSync(
                text: item.text,
                preferRemoteOverride: item.preferRemoteVoiceOverride,
                onAudioStart: {
                    LiveSubtitleStore.shared.startedPlaying(item)
                }
            )
            // Preemption path cancels this task before resuming the
            // underlying TTS continuation. A cancelled task must not touch
            // `currentlyPlaying` — the cancel path has already replaced it.
            if Task.isCancelled { return }
            guard let self else { return }
            // Subtitle now enters dwell window (still on screen, audio
            // done) so the user can hit heart.
            LiveSubtitleStore.shared.finishedPlaying(item)
            self.dispatched += 1
            self.currentlyPlaying = nil
            self.kickNext()
        }
    }

    // MARK: - Session deactivate

    private var deactivateTask: Task<Void, Never>?

    private func scheduleSessionDeactivate() {
        deactivateTask?.cancel()
        deactivateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            // Only deactivate if still idle. Another enqueue may have arrived.
            guard self.currentlyPlaying == nil, self.pending.isEmpty else { return }
            AudioPlaybackManager.shared.deactivate()
        }
    }
}
