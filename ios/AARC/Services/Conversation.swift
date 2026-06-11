import Foundation
import Observation
import OSLog
import AARCKit

/// Orchestrates the second voice — Jessica. When Ricky (ScriptEngine or
/// ContextualCoach) speaks a line, the dispatcher calls `rickySpoke`. This
/// asks the Director whether there's room in the timeline, and if so
/// generates Jessica's reaction via `/react-line` and enqueues it right
/// behind his line at the SAME priority + a shared `segmentId`, so the
/// two play as an atomic two-hander.
///
/// Additive by design: the primary voice's generation and dispatch are
/// unchanged. If Jessica is disabled, there's no room, or the line is itself
/// a Jessica reply, this is a no-op.
@MainActor
@Observable
final class Conversation {
    static let shared = Conversation()

    private static let kEnabled = "aarc.voice.jessicaEnabled"

    /// Master switch for the second voice. Persisted; defaults on.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.kEnabled) }
    }

    // Diagnostic state.
    private(set) var lastReaction: String?
    private(set) var lastError: String?

    private var inFlight: Task<Void, Never>?
    private let log = Logger(subsystem: "club.aarun.AARC", category: "Conversation")

    // MARK: - Cadence + length bookkeeping
    //
    // Jessica used to react to EVERY Ricky line with a one-minute monologue.
    // The founder still wants music, Ricky, and performance feedback in the
    // mix — so she now reacts to roughly HALF of eligible lines, mostly with
    // short quips and only occasionally with a long indulgent passage.

    /// Length tiers we ask the proxy for. Raw values match the proxy's
    /// `lengthMode` contract ("quip" | "medium" | "indulgent").
    private enum LengthMode: String {
        case quip
        case medium
        case indulgent
    }

    /// Elapsed-seconds (run clock) of the last reaction we actually fired.
    /// Used to space her out so she isn't wall-to-wall.
    private var lastReactionElapsed: TimeInterval?
    /// Elapsed-seconds of the last INDULGENT passage, so two long ones can
    /// never land back to back (and rarely even within several minutes).
    private var lastIndulgentElapsed: TimeInterval?
    /// Monotonic count of reactions fired this run — diagnostic bookkeeping
    /// (the gate itself is driven by the deterministic variation hash).
    private(set) var reactionCount: Int = 0

    /// Don't react more often than this (run-clock seconds between reactions),
    /// regardless of how chatty Ricky gets. Keeps air for music + feedback.
    private let minGapBetweenReactions: TimeInterval = 18
    /// An indulgent passage runs long; never run two within this window.
    private let minGapBetweenIndulgent: TimeInterval = 240
    /// Only allow an indulgent passage when there's at least this much clear
    /// air before the next must-play. The passage is ~30-50s of audio plus
    /// Ricky's line ahead of it, so we want comfortable margin.
    private let indulgentRoomFloor: TimeInterval = 70
    /// Above this much clear air a "medium" reply fits comfortably.
    private let mediumRoomFloor: TimeInterval = 30

    init() {
        let store = UserDefaults.standard
        if store.object(forKey: Self.kEnabled) == nil {
            store.set(true, forKey: Self.kEnabled)
        }
        self.enabled = store.bool(forKey: Self.kEnabled)
    }

    /// Called right after Ricky speaks a line. `segmentId` must match the
    /// one the caller tagged Ricky's line with, so the queue can keep the
    /// pair atomic. No-op if Jessica is disabled, the Director says there's
    /// no room, or `source` is itself a Jessica line (never react to a
    /// reaction — that would loop).
    func rickySpoke(
        text: String,
        source: String,
        priority: VoicePriority,
        segmentId: UUID,
        metrics: LiveMetrics
    ) {
        guard enabled else { return }
        guard !source.hasPrefix("jessica") else { return }
        guard RunDirector.shared.hasRoomForExchange else {
            log.info("Jessica skipped — no room before next must-play")
            RunEventLog.shared.record("jessica.skip", "no room", data: ["to": source])
            return
        }

        // FREQUENCY GATE — she reacts to ~half of eligible lines, and never
        // more often than `minGapBetweenReactions`. Milestone/finish lines
        // (priority .milestone) earn a near-certain reaction; ambient banter
        // (priority .banter — music/lyric riffs) earns the fewest.
        let elapsed = metrics.elapsed
        if let last = lastReactionElapsed, elapsed - last < minGapBetweenReactions {
            log.info("Jessica skipped — within min gap")
            RunEventLog.shared.record("jessica.skip", "too soon", data: ["to": source])
            return
        }
        guard shouldReact(to: priority, elapsed: elapsed, distance: metrics.distanceMeters) else {
            log.info("Jessica skipped — frequency gate")
            RunEventLog.shared.record("jessica.skip", "cadence", data: ["to": source])
            return
        }

        // LENGTH SELECTOR — default heavily toward quip; medium sometimes;
        // indulgent only with lots of room and none recently.
        let room = RunDirector.shared.roomSecondsForExchange
        let mode = pickLengthMode(room: room, elapsed: elapsed, distance: metrics.distanceMeters)

        let plan = ScriptPreviewStore.shared.currentPlan
        let runType = LiveMetricsConsumer.shared.pendingRunType
        // Project forward too — Jessica plays after Ricky, so if she quotes
        // a number it should match where the runner is by then.
        let projected = RunDirector.shared.projected(
            distance: metrics.distanceMeters,
            elapsed: metrics.elapsed
        )
        let context = AIClient.ReactLineContext(
            elapsedSeconds: projected.elapsed,
            distanceMeters: projected.distance,
            currentHR: metrics.currentHeartRate,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            planKind: plan.kind.rawValue,
            runType: runType.rawValue
        )
        let recent = ScriptEngine.shared.recentDispatchedLines
        let notes = PersonalContextStore.shared.bullets
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: "jessica")
        let request = AIClient.ReactLineRequest(
            personalityId: "jessica",
            partnerLine: text,
            partnerSource: source,
            runContext: context,
            recentDispatched: recent.isEmpty ? nil : recent,
            personalNotes: notes.isEmpty ? nil : notes,
            likedLineExamples: liked.isEmpty ? nil : liked,
            lengthMode: mode.rawValue
        )

        // Commit the cadence bookkeeping at decision time (not after the
        // network round-trip) so a burst of Ricky lines can't all slip
        // through the gate while a reaction is still generating.
        reactionCount += 1
        lastReactionElapsed = elapsed
        if mode == .indulgent { lastIndulgentElapsed = elapsed }

        // Expiry must outlast the queue's music-gap wait (~28s) plus synth,
        // or she'd expire before her turn. Quips still expire sooner than
        // long passages (a stale quip behind a split is worthless), just not
        // so soon they never play.
        let expiry: TimeInterval = mode == .quip ? 55 : 95

        log.info("Jessica reacting to \(source, privacy: .public) len=\(mode.rawValue, privacy: .public)")
        // Only one reaction in flight; a fresh Ricky line supersedes a
        // not-yet-spoken reaction to the previous one.
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = nil }
            do {
                let result = try await AIClient.shared.reactLine(request)
                guard !Task.isCancelled, ScriptEngine.shared.isActive else { return }
                // Pre-render her audio NOW, while she waits her turn — so when
                // the queue releases her into the music gap there's no
                // synth-stall ducking the music. (This is also why we don't
                // glue her to Ricky's tail any more.)
                await RemoteTTS.shared.prefetch(result.text, voiceId: RemoteTTS.jessicaVoiceId)
                guard !Task.isCancelled, ScriptEngine.shared.isActive else { return }
                // Newest comment wins: drop any earlier Jessica line still
                // waiting in the queue so she doesn't stack up — she reacts to
                // the most recent thing Ricky said, a beat later, in the gap.
                VoiceFeedbackQueue.shared.dropPending(sourcePrefix: "jessica")
                // Enqueue STANDALONE at .coaching (no shared segmentId, no
                // atomic-pair gluing). The queue's music-gap pacing decides
                // WHEN she lands; .coaching means a coach line can't preempt
                // her mid-sentence (only a km split can now).
                Speaker.shared.speak(
                    result.text,
                    priority: .coaching,
                    source: "jessica:react",
                    expiresAfter: expiry,
                    voiceId: RemoteTTS.jessicaVoiceId
                )
                self.lastReaction = result.text
                self.lastError = nil
                RunEventLog.shared.record("jessica.react", String(result.text.prefix(80)),
                                          data: ["to": source, "len": mode.rawValue])
            } catch {
                if Task.isCancelled { return }
                self.lastError = error.localizedDescription
                self.log.error("Jessica reactLine error: \(error.localizedDescription, privacy: .public)")
                // Surface the final failure (post-retry) so a repeating
                // mid-run failure mode — like the 400-for-an-hour
                // over-long-exemplar bug — is visible after the run, not
                // just in a live Console session.
                CrashReporter.captureMessage("Jessica reactLine failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cadence + length policy

    /// Deterministic 0..<1 variation derived from the run state — a hash of
    /// elapsed seconds + distance (+ a `salt` so two independent decisions
    /// off the same run state don't correlate), NOT a nondeterministic RNG.
    /// Same run state ⇒ same value, so behaviour is reproducible in the
    /// Playground and in replay, while still varying smoothly across the run.
    private func variation(elapsed: TimeInterval, distance: Double, salt: UInt64) -> Double {
        // Fold both axes into an integer, then run a cheap integer hash
        // (splitmix64-style) and normalise. Distance is weighted so two
        // lines a second apart at different points still diverge. The salt
        // gives the frequency gate and the length selector statistically
        // independent draws from the same (elapsed, distance) point.
        var x = UInt64(bitPattern: Int64(elapsed.rounded()))
            &+ (UInt64(bitPattern: Int64(distance.rounded())) &* 2_654_435_761)
            &+ salt
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        x = x ^ (x >> 31)
        return Double(x >> 11) / Double(1 << 53)
    }

    /// Frequency gate: should she react to THIS line at all? Targets ~half
    /// of eligible lines overall, biased by the line's importance:
    ///   • .milestone (km split / halfway / finish) → almost always
    ///   • .coaching  (HR / pace observations)      → ~half
    ///   • .banter    (music / lyric riffs)         → least often
    /// The decision is deterministic (variation hash), so it's reproducible.
    private func shouldReact(to priority: VoicePriority, elapsed: TimeInterval, distance: Double) -> Bool {
        // Raised across the board (only 1 of her reactions was actually
        // HEARD last run — she was over-gated AND getting preempted). The
        // queue's music-gap pacing + newest-wins now space her safely, so
        // we can let her react far more often and trust playback timing to
        // keep the floor breathing.
        let threshold: Double
        switch priority {
        case .milestone: threshold = 0.95   // nearly every split/finish
        case .coaching:  threshold = 0.78   // most pace/HR lines
        case .banter:    threshold = 0.50   // half of music/lyric riffs
        }
        return variation(elapsed: elapsed, distance: distance, salt: 0x9E37_79B9_7F4A_7C15) < threshold
    }

    /// Length selector. Default heavily toward `.quip`; pick `.medium`
    /// sometimes; pick `.indulgent` only when the Director has LOTS of room
    /// AND no indulgent has run recently. Deterministic variation breaks the
    /// medium/quip split so it isn't fixed.
    private func pickLengthMode(room: TimeInterval, elapsed: TimeInterval, distance: Double) -> LengthMode {
        let v = variation(elapsed: elapsed, distance: distance, salt: 0xD1B5_4A32_D192_ED03)

        // Indulgent: needs comfortable clear air AND a cool-down since the
        // last long passage — and even then only on the rare end of the
        // variation, so it's genuinely occasional, never back-to-back.
        let indulgentClear = lastIndulgentElapsed.map { elapsed - $0 >= minGapBetweenIndulgent } ?? true
        if room >= indulgentRoomFloor, indulgentClear, v >= 0.88 {
            return .indulgent
        }

        // Medium: only with enough room, and only some of the time — most
        // replies stay quips so music / Ricky / feedback keep the floor.
        if room >= mediumRoomFloor, v >= 0.55 {
            return .medium
        }

        return .quip
    }

    /// Cancel any in-flight reaction. Called at run end so a late reply
    /// can't speak after the pipeline is torn down. Also clears cadence
    /// bookkeeping so the next run starts fresh.
    func stop() {
        inFlight?.cancel()
        inFlight = nil
        lastReactionElapsed = nil
        lastIndulgentElapsed = nil
        reactionCount = 0
    }
}
