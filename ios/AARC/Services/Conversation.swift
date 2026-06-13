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
    /// Her OWN recent lines — fed back into the generator so she stops
    /// repeating the same keyword / manner a few lines running (which read
    /// mechanical and boring). The pre-generated/pending line lives here too
    /// (it's appended at generation time), so the NEXT line sees it.
    private var recentJessica: [String] = []

    // MARK: - Tunables

    /// BACK-LOADED cadence: seconds between generations, long early (sparse —
    /// music + a few Ricky jokes carry the pumped opening) shrinking late
    /// (frequent — Jessica's vivid fuel for the painful back half). Picked by
    /// `currentCooldown()` off RunDirector.progressFraction.
    private let earlyCooldown: TimeInterval = 150
    private let lateCooldown: TimeInterval = 72
    /// Length gates (reuse the proxy's lengthMode contract).
    private let indulgentRoomFloor: TimeInterval = 70
    private let minGapBetweenIndulgent: TimeInterval = 240
    private let mediumRoomFloor: TimeInterval = 30

    /// Generation cadence for THIS moment — long early, short late.
    private func currentCooldown() -> TimeInterval {
        let p = RunDirector.shared.progressFraction
        return earlyCooldown + (lateCooldown - earlyCooldown) * p
    }

    /// Merge Ricky's recent lines + her own recent lines into one anti-repeat
    /// context (capped), so the generator can avoid reusing either voice's
    /// ideas, phrasing, or openers.
    private func antiRepeatContext() -> [String] {
        var recent = ScriptEngine.shared.recentDispatchedLines
        recent.append(contentsOf: recentJessica)
        // Clamp BOTH count and per-entry length to stay under the proxy caps
        // (array ≤16, each ≤1200). The array-count overflow (>10 old cap)
        // 400'd Jessica ~9 min in once enough lines accumulated; suffix(12)
        // + the raised 16 cap leave headroom either way.
        return Array(recent.suffix(12)).map { String($0.prefix(1100)) }
    }

    private func rememberJessica(_ line: String) {
        recentJessica.append(line)
        if recentJessica.count > 6 { recentJessica.removeFirst(recentJessica.count - 6) }
    }

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
              // Cadence from the LAST production, or from t=0 for the first —
              // so her opening entrance also waits out the long early cooldown
              // (the start stays Ricky + music while the founder's pumped).
              (elapsed - (lastProducedElapsed ?? 0) >= currentCooldown()),
              (!recentRicky.isEmpty || elapsed > 60),
              RunDirector.shared.hasRoomForExchange
        else { return }

        startProducing(metrics)
    }

    /// Jessica TAKES a per-km milestone (intertwined with Ricky, her share
    /// rising late). Called by ScriptEngine when the Director assigns this km
    /// to her: it skips Ricky's scripted riff and Jessica delivers instead.
    func deliverMilestone(km: Int, metrics: LiveMetrics) {
        guard enabled, RunDirector.shared.isActive else { return }
        // One of hers at a time; don't stack on a pending line.
        guard !isProducing, !VoiceFeedbackQueue.shared.hasPending(sourcePrefix: "jessica") else { return }
        startProducing(metrics, milestoneKm: km)
    }

    private func startProducing(_ metrics: LiveMetrics, milestoneKm: Int? = nil) {
        isProducing = true
        lastProducedElapsed = metrics.elapsed

        // Milestone moments are her REWARD — vivid by design (indulgent late,
        // medium earlier). Ambient lines use the room/progress-curved pick.
        let mode: LengthMode
        if let km = milestoneKm {
            mode = RunDirector.shared.progressFraction >= 0.55 ? .indulgent : .medium
            _ = km
        } else {
            mode = pickLengthMode(
                room: RunDirector.shared.roomSecondsForExchange,
                elapsed: metrics.elapsed,
                distance: metrics.distanceMeters)
        }

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
            runType: runType.rawValue,
            place: PlaceContext.shared.llmInfo
        )
        // On a milestone she riffs off the marker itself; otherwise off
        // Ricky's recent line.
        let partner: String
        let partnerSource: String
        if let km = milestoneKm {
            partner = "He's just crossed \(km) kilometres."
            partnerSource = "milestone:km:\(km)"
        } else {
            partner = recentRicky.last ?? "the run so far"
            partnerSource = lastRickySource
        }
        let recent = antiRepeatContext()
        let notes = PersonalContextStore.shared.bullets
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: "jessica")
        let request = AIClient.ReactLineRequest(
            personalityId: "jessica",
            partnerLine: partner,
            partnerSource: partnerSource,
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
                if mode == .indulgent { self.lastIndulgentElapsed = metrics.elapsed }
                // Remember it so the NEXT line doesn't echo it.
                self.rememberJessica(result.text)
                // A milestone lands prominently (.milestone, can preempt) and
                // expires sooner if it's too late; an ambient line rides the
                // queue's music gap at .coaching.
                if let km = milestoneKm {
                    Speaker.shared.speak(
                        result.text,
                        priority: .milestone,
                        source: "jessica:milestone:\(km)",
                        expiresAfter: 45,
                        voiceId: RemoteTTS.jessicaVoiceId)
                } else {
                    Speaker.shared.speak(
                        result.text,
                        priority: .coaching,
                        source: "jessica:react",
                        expiresAfter: 90,
                        voiceId: RemoteTTS.jessicaVoiceId)
                }
                self.lastReaction = result.text
                self.lastError = nil
                RunEventLog.shared.record("jessica.ready", String(result.text.prefix(70)),
                                          data: ["len": mode.rawValue,
                                                 "km": milestoneKm.map(String.init) ?? ""])
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
        // Vivid fuel is back-loaded: late in the run she goes long far more
        // often (the founder wants her detailed actions as fuel after the
        // halfway pain). Lower thresholds = more medium/indulgent.
        let p = RunDirector.shared.progressFraction
        let indulgentThresh = max(0.76, 0.93 - 0.22 * p)
        let mediumThresh = max(0.38, 0.60 - 0.26 * p)
        if room >= indulgentRoomFloor, indulgentClear, v >= indulgentThresh { return .indulgent }
        if room >= mediumRoomFloor, v >= mediumThresh { return .medium }
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
        recentJessica.removeAll()
    }
}
