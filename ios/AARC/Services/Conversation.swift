import Foundation
import Observation
import OSLog
import AARCKit

/// The second voice — Jessica — as a BACKGROUND PRODUCER, not a reactive
/// echo of Ricky.
///
/// The old design generated a fresh reaction the instant Ricky spoke, glued
/// behind his line. On a busy opening that trap fired: Ricky speaks → start
/// generating Jessica (~10s LLM + ~10s TTS) → Ricky speaks again → her line
/// expires unplayed. Voices piled up, two dropped stale, and the TTS
/// pipeline sat idle through every music gap.
///
/// Now she runs as a steady background job, fully decoupled from Ricky's
/// cadence:
///   • `rickySpoke` only records loose CONTEXT (the last few Ricky lines).
///   • `tick` (1 Hz) keeps exactly ONE line PRE-GENERATED and PRE-RENDERED
///     in the chamber, produced in the background while music plays, and
///     RELEASES it into a genuine quiet gap.
/// She's deliberately "less real-time": she comments on the recent vibe a
/// beat later, in the open air, instead of racing Ricky in lockstep. That's
/// the compromise that lets the run actually breathe.
@MainActor
@Observable
final class Conversation {
    static let shared = Conversation()

    private static let kEnabled = "aarc.voice.jessicaEnabled"

    /// Master switch for the second voice. Persisted; defaults on. Turning
    /// her off mid-run cancels any in-flight production so a line can't land
    /// after she was silenced.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.kEnabled)
            if !enabled {
                produceTask?.cancel()
                produceTask = nil
                isProducing = false
            }
        }
    }

    // Diagnostic state (observed by the Control Room).
    private(set) var lastReaction: String?
    private(set) var lastError: String?
    private(set) var isProducing: Bool = false

    private let log = Logger(subsystem: "club.aarun.AARC", category: "Conversation")

    // MARK: - Producer state

    private var produceTask: Task<Void, Never>?
    private var lastProducedElapsed: TimeInterval?
    private var lastIndulgentElapsed: TimeInterval?

    /// Rolling context — the last few things Ricky said, so she has
    /// something to riff on without reacting to one exact line.
    private var recentRicky: [String] = []
    private var lastRickySource: String = "the run"

    // MARK: - Tunables

    /// Min run-clock seconds between STARTING two generations — caps LLM/TTS
    /// spend so she produces at roughly the rate she can be heard. The QUEUE
    /// (its 35s music gap) is the single pacing authority for WHEN a line
    /// actually plays; this just throttles how often we generate one.
    private let produceCooldown: TimeInterval = 42
    /// Length gates (reuse the proxy's lengthMode contract).
    private let indulgentRoomFloor: TimeInterval = 70
    private let minGapBetweenIndulgent: TimeInterval = 300
    private let mediumRoomFloor: TimeInterval = 30

    init() {
        let store = UserDefaults.standard
        if store.object(forKey: Self.kEnabled) == nil {
            store.set(true, forKey: Self.kEnabled)
        }
        self.enabled = store.bool(forKey: Self.kEnabled)
    }

    // MARK: - Context intake (called where Ricky speaks)

    /// Records loose context only — NO generation here any more. Keeps the
    /// signature the existing callers (ScriptEngine / ContextualCoach) use so
    /// nothing else changes.
    func rickySpoke(
        text: String,
        source: String,
        priority: VoicePriority,
        segmentId: UUID,
        metrics: LiveMetrics
    ) {
        guard enabled, !source.hasPrefix("jessica") else { return }
        recentRicky.append(text)
        if recentRicky.count > 4 { recentRicky.removeFirst() }
        lastRickySource = source
    }

    // MARK: - 1 Hz pump (called from LiveMetricsConsumer.ingest)

    /// Keep ONE Jessica line flowing into the queue at a throttled rate;
    /// the queue's music gap decides when it actually plays. Cheap when
    /// there's nothing to do.
    func tick(_ metrics: LiveMetrics) {
        // Gate on the RUN being active (RunDirector starts for EVERY run),
        // not the script engine — open / scriptless runs have no
        // ScriptEngine but still want a second voice.
        guard enabled, RunDirector.shared.isActive else { return }
        let elapsed = metrics.elapsed

        // PRODUCE one line when: nothing already producing, none of hers is
        // still queued/playing, the throttle has elapsed, there's something
        // to riff on (or we're past the opener), and there's clear air
        // before the next must-play split so she can't be guillotined.
        guard !isProducing,
              !VoiceFeedbackQueue.shared.hasPending(sourcePrefix: "jessica"),
              (lastProducedElapsed.map { elapsed - $0 >= produceCooldown } ?? true),
              (!recentRicky.isEmpty || elapsed > 60),
              RunDirector.shared.hasRoomForExchange
        else { return }

        startProducing(metrics)
    }

    private func startProducing(_ metrics: LiveMetrics) {
        isProducing = true
        lastProducedElapsed = metrics.elapsed

        let mode = pickLengthMode(
            room: RunDirector.shared.roomSecondsForExchange,
            elapsed: metrics.elapsed,
            distance: metrics.distanceMeters
        )

        // Project the numbers forward by the pipeline lead so anything she
        // quotes is roughly right by the time she's heard.
        let projected = RunDirector.shared.projected(
            distance: metrics.distanceMeters, elapsed: metrics.elapsed)
        let plan = ScriptPreviewStore.shared.currentPlan
        let runType = LiveMetricsConsumer.shared.pendingRunType
        let context = AIClient.ReactLineContext(
            elapsedSeconds: projected.elapsed,
            distanceMeters: projected.distance,
            currentHR: metrics.currentHeartRate,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            planKind: plan.kind.rawValue,
            runType: runType.rawValue
        )
        let partner = recentRicky.last ?? "the run so far"
        let recent = ScriptEngine.shared.recentDispatchedLines
        let notes = PersonalContextStore.shared.bullets
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: "jessica")
        let request = AIClient.ReactLineRequest(
            personalityId: "jessica",
            partnerLine: partner,
            partnerSource: lastRickySource,
            runContext: context,
            recentDispatched: recent.isEmpty ? nil : recent,
            personalNotes: notes.isEmpty ? nil : notes,
            likedLineExamples: liked.isEmpty ? nil : liked,
            lengthMode: mode.rawValue
        )
        produceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProducing = false; self.produceTask = nil }
            do {
                let result = try await AIClient.shared.reactLine(request)
                guard !Task.isCancelled, self.enabled, RunDirector.shared.isActive else { return }
                // PRE-RENDER her audio in the background while music plays —
                // so when the queue's gap opens she plays instantly, no
                // ducked synth stall.
                await RemoteTTS.shared.prefetch(result.text, voiceId: RemoteTTS.jessicaVoiceId)
                guard !Task.isCancelled, self.enabled, RunDirector.shared.isActive else { return }
                // Commit the indulgent cool-down only now that a long line
                // actually exists — a failed/cancelled produce mustn't burn
                // the 5-minute window.
                if mode == .indulgent { self.lastIndulgentElapsed = metrics.elapsed }
                // ENQUEUE straight away. The queue's 35s music gap is the
                // single authority on WHEN she plays — she lands in the next
                // quiet stretch, pre-rendered, no double-gating.
                Speaker.shared.speak(
                    result.text,
                    priority: .coaching,
                    source: "jessica:react",
                    expiresAfter: 90,
                    voiceId: RemoteTTS.jessicaVoiceId
                )
                self.lastReaction = result.text
                self.lastError = nil
                RunEventLog.shared.record("jessica.ready", String(result.text.prefix(70)),
                                          data: ["len": mode.rawValue])
            } catch {
                if Task.isCancelled { return }
                self.lastError = error.localizedDescription
                self.log.error("Jessica produce error: \(error.localizedDescription, privacy: .public)")
                CrashReporter.captureMessage("Jessica produce failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Length policy

    private enum LengthMode: String { case quip, medium, indulgent }

    /// Deterministic 0..<1 variation from the run state (no live RNG, so it's
    /// reproducible in the Playground / replay).
    private func variation(elapsed: TimeInterval, distance: Double, salt: UInt64) -> Double {
        var x = UInt64(bitPattern: Int64(elapsed.rounded()))
            &+ (UInt64(bitPattern: Int64(distance.rounded())) &* 2_654_435_761)
            &+ salt
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        x = x ^ (x >> 31)
        return Double(x >> 11) / Double(1 << 53)
    }

    /// Mostly quips; medium sometimes; indulgent only with lots of clear air
    /// and a long cool-down (it's now pre-rendered, so length costs latency
    /// nothing — but a minute of Jessica still steals the music's air, so
    /// keep it rare).
    private func pickLengthMode(room: TimeInterval, elapsed: TimeInterval, distance: Double) -> LengthMode {
        let v = variation(elapsed: elapsed, distance: distance, salt: 0xD1B5_4A32_D192_ED03)
        let indulgentClear = lastIndulgentElapsed.map { elapsed - $0 >= minGapBetweenIndulgent } ?? true
        if room >= indulgentRoomFloor, indulgentClear, v >= 0.90 { return .indulgent }
        if room >= mediumRoomFloor, v >= 0.58 { return .medium }
        return .quip
    }

    // MARK: - Lifecycle

    /// Tear down at run end so a late reply can't speak after the pipeline
    /// is gone, and the next run starts clean.
    func stop() {
        produceTask?.cancel()
        produceTask = nil
        isProducing = false
        lastProducedElapsed = nil
        lastIndulgentElapsed = nil
        recentRicky.removeAll()
    }
}
