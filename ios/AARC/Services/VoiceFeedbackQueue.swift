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
    /// ElevenLabs voice for this line. nil → the default Roast Coach voice.
    /// Jessica's lines carry her voice id here.
    let voiceId: String?
    /// Links a his→her exchange. When one member is preempted or dropped,
    /// its siblings are purged so an orphaned reaction can't play out of
    /// context. nil for standalone lines.
    let segmentId: UUID?
    /// When the run-state used to generate this line was snapshotted. Set
    /// only on freshly-generated coach lines so the queue can measure the
    /// gen→audible latency and feed the Director's lookahead. nil for
    /// scripted / cached / reaction lines.
    let decisionAt: Date?

    init(
        id: UUID = UUID(),
        text: String,
        priority: VoicePriority,
        source: String,
        dedupKey: String? = nil,
        createdAt: Date = .now,
        expiresAfter: TimeInterval? = nil,
        preferRemoteVoiceOverride: Bool? = nil,
        voiceId: String? = nil,
        segmentId: UUID? = nil,
        decisionAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.source = source
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.expiresAfter = expiresAfter
        self.preferRemoteVoiceOverride = preferRemoteVoiceOverride
        self.voiceId = voiceId
        self.segmentId = segmentId
        self.decisionAt = decisionAt
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
    /// When the last spoken line FINISHED (audio done). Drives the music
    /// breathing-room gap so voices don't pile up wall-to-wall — the floor
    /// returns to music between speakers, like a radio show. nil = none yet.
    private(set) var lastVoiceEndedAt: Date?

    // MARK: - Radio pacing

    /// Minimum music time between the END of one non-milestone line and the
    /// START of the next, so the runner gets to enjoy the music before
    /// someone talks again. km splits / finish (.milestone) are exempt —
    /// they must land on the marker. ~35s ≈ a verse-and-chorus of music
    /// before the next voice — the founder wants to actually enjoy the song.
    /// Tunable: raise for more music, lower for a chattier mix.
    let minMusicGapSeconds: TimeInterval = 35

    /// Seconds of music since the last line ended. Large when nothing has
    /// played yet (so the opener never waits). Read by ContextualCoach /
    /// Conversation to decide whether there's been enough music.
    var secondsSinceLastVoice: TimeInterval {
        guard let end = lastVoiceEndedAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(end)
    }

    /// Nothing playing and nothing queued — a true quiet stretch.
    var isIdle: Bool { currentlyPlaying == nil && pending.isEmpty }

    // MARK: - Internal

    private let log = Logger(subsystem: "club.aarun.AARC", category: "VoiceQueue")
    private var playbackTask: Task<Void, Never>?
    /// Fires when a gap-deferred non-milestone line is due to start.
    private var gapTask: Task<Void, Never>?

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

        // Preemption is now RESERVED FOR km-split milestones. Coach lines
        // and lyric riffs no longer cut off a line that's already speaking —
        // that's what was guillotining Jessica mid-sentence ("a coach line
        // preempted her"). Only a .milestone (split/halfway/finish) may
        // interrupt, because it has to land on the marker.
        if let cur = currentlyPlaying, item.priority == .milestone, cur.priority < .milestone {
            log.info("VoiceQueue preempt cur=\(cur.source, privacy: .public)(\(cur.priority.rawValue)) by milestone=\(item.source, privacy: .public)")
            preempted += 1
            RunEventLog.shared.record("voice.preempt", String(item.text.prefix(80)),
                                      data: ["cut": cur.source, "by": item.source])
            // Cancel the outstanding task BEFORE resuming its continuation,
            // so the awaited body sees Task.isCancelled == true and bails
            // without clobbering the new item.
            playbackTask?.cancel()
            playbackTask = nil
            Speaker.shared.stopActiveBackend()
            // If the preempted line was half of a two-voice exchange, drop
            // its partner too — an orphaned reaction to a cut-off line
            // would play out of context.
            if let seg = cur.segmentId {
                pending.removeAll { $0.segmentId == seg }
            }
            currentlyPlaying = nil
            // Push the milestone to the front of the queue, then drain.
            pending.insert(item, at: 0)
            gapTask?.cancel()
            kickNext()
            return
        }

        // Otherwise queue it, sorted by priority desc, FIFO within priority.
        // If nothing is playing, drain — kickNext() honours the music gap, so
        // we route through it (NOT startPlaying directly) to keep the
        // breathing-room pacing intact even when the queue was idle.
        insertSorted(item)
        log.debug("VoiceQueue enqueue src=\(item.source, privacy: .public) pri=\(item.priority.rawValue) pending=\(self.pending.count)")
        // Keep the ElevenLabs pipeline BUSY: start rendering this line's
        // audio in the background NOW, while the music plays, so it's
        // cache-warm by the time its slot opens. Without this the synth
        // happened at dequeue — a 10-12s lead per line with the pipeline
        // idle through every music gap.
        prewarm(item)
        if currentlyPlaying == nil { kickNext() }
    }

    /// True if a line whose source begins with `prefix` is currently playing
    /// or waiting in the queue. Lets the Jessica producer keep at most one of
    /// hers in flight without a separate slot.
    func hasPending(sourcePrefix prefix: String) -> Bool {
        if let cur = currentlyPlaying, cur.source.hasPrefix(prefix) { return true }
        return pending.contains { $0.source.hasPrefix(prefix) }
    }

    /// Pending RICKY ambient lines (coach lines, lyric riffs) below milestone
    /// priority — EXCLUDING Jessica, so the two voices stay decoupled: her
    /// queued line must never throttle his coaching.
    var pendingRickyAmbientCount: Int {
        pending.reduce(0) {
            $0 + (($1.priority < .milestone && !$1.source.hasPrefix("jessica")) ? 1 : 0)
        }
    }

    /// True when there's room to GENERATE another Ricky ambient line without
    /// backing his side up. One in the chamber is enough — generating more
    /// just makes lines expire unplayed behind the music gap (the stale-drop
    /// waste). Milestones and Jessica are never counted here.
    var ambientChamberFree: Bool { pendingRickyAmbientCount == 0 }

    /// Pre-render an item's audio in the background. Idempotent — a cache
    /// hit is an instant no-op, so calling it for already-warm lines is free.
    private func prewarm(_ item: VoiceItem) {
        guard !AudioPlaybackManager.shared.isMuted else { return }
        guard item.voiceId != nil || Speaker.shared.preferRemoteVoice else { return }
        let voice = item.voiceId ?? RemoteTTS.voiceId
        let text = item.text
        Task { @MainActor in
            guard !AudioPlaybackManager.shared.isMuted else { return }
            await RemoteTTS.shared.prefetch(text, voiceId: voice)
        }
    }

    /// Stop everything immediately: cancel current playback, clear the queue,
    /// deactivate the audio session. Called by the mute toggle and at end of
    /// run.
    func stopAll() {
        playbackTask?.cancel()
        playbackTask = nil
        gapTask?.cancel()
        gapTask = nil
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
        // Fresh run: no prior voice, so the opener plays without waiting on
        // the music gap.
        lastVoiceEndedAt = nil
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
        // RADIO PACING: non-milestone lines wait until enough music has
        // played since the last line ended. Milestones (km splits / finish)
        // bypass — they have to land on the marker. This is what gives the
        // run its "DJ speaks, then music breathes, then the next voice"
        // rhythm instead of voices stacking back-to-back.
        if next.priority < .milestone {
            let waited = secondsSinceLastVoice
            let remaining = minMusicGapSeconds - waited
            if remaining > 0.3 {
                // Put it back at the front and try again after the gap.
                pending.insert(next, at: 0)
                RunEventLog.shared.record("voice.deferGap", String(next.text.prefix(60)),
                                          data: ["source": next.source,
                                                 "wait": String(format: "%.0f", remaining)])
                scheduleGapKick(after: remaining)
                return
            }
        }
        startPlaying(next)
    }

    /// Re-attempt the queue after `seconds` of music breathing room.
    private func scheduleGapKick(after seconds: TimeInterval) {
        gapTask?.cancel()
        gapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.3, seconds)))
            guard let self, !Task.isCancelled else { return }
            guard self.currentlyPlaying == nil else { return }
            self.kickNext()
        }
    }

    private func popNextNonStale() -> VoiceItem? {
        while let candidate = pending.first {
            pending.removeFirst()
            if candidate.isStale() {
                droppedStale += 1
                log.info("VoiceQueue drop stale src=\(candidate.source, privacy: .public)")
                RunEventLog.shared.record("voice.dropStale", String(candidate.text.prefix(80)),
                                          data: ["source": candidate.source])
                // Drop the rest of the exchange too if this was part of one.
                if let seg = candidate.segmentId {
                    pending.removeAll { $0.segmentId == seg }
                }
                continue
            }
            return candidate
        }
        return nil
    }

    private func startPlaying(_ item: VoiceItem) {
        currentlyPlaying = item
        lastDispatchedAt = .now
        RunEventLog.shared.record("voice.play", String(item.text.prefix(80)),
                                  data: ["source": item.source, "priority": String(item.priority.rawValue)])
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
            // PREFETCH BEFORE DUCK: render the audio to cache with the music
            // still at full volume. The old path ducked the music the instant
            // the line was dequeued and then sat in 10-15s of near-silence
            // while ElevenLabs synthesised (every `tts.play` was cached:false).
            // Warming first means playSync below is a cache HIT, so the duck
            // and the first syllable are back-to-back — no dead air.
            if item.voiceId != nil || Speaker.shared.preferRemoteVoice {
                await RemoteTTS.shared.prefetch(item.text, voiceId: item.voiceId ?? RemoteTTS.voiceId)
            }
            if Task.isCancelled { return }

            await Speaker.shared.playSync(
                text: item.text,
                voiceId: item.voiceId,
                preferRemoteOverride: item.preferRemoteVoiceOverride,
                onAudioStart: {
                    LiveSubtitleStore.shared.startedPlaying(item)
                    // Measure the gen→audible latency for fresh coach lines
                    // so the Director can project live numbers forward.
                    if let decisionAt = item.decisionAt {
                        RunDirector.shared.recordPipelineLatency(Date().timeIntervalSince(decisionAt))
                    }
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
            // Mark the start of the music breathing-room gap.
            self.lastVoiceEndedAt = .now
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
