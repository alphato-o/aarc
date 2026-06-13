import Foundation
import Observation
import AARCKit

/// The "brain" that turns the watch's 1 Hz `LiveMetrics` stream into
/// spoken lines at the right moments. Subscribes to whatever script is
/// currently active, evaluates each message's `triggerSpec` against
/// every metric tick, and dispatches matching messages to the
/// `VoiceFeedbackQueue` (via `Speaker`) at `.milestone` priority.
///
/// Plan-aware: `halfway`, `near_finish`, and `finish` triggers
/// evaluate against distance for `.distance` plans, against elapsed
/// time for `.time` plans, and never fire for `.open` plans (the
/// model is instructed not to emit them in that case anyway).
///
/// Playback serialisation is now owned by `VoiceFeedbackQueue` — this
/// engine just enqueues and trusts the queue to keep things tidy. The
/// old 10s time-based cooldown is gone; instead, per-message epoch
/// tracking and `playOnce` gates prevent the same milestone from being
/// enqueued twice.
@Observable
@MainActor
final class ScriptEngine {
    static let shared = ScriptEngine()

    /// True while a script is loaded and a run is in progress.
    private(set) var isActive: Bool = false

    /// Identifier of the script currently driving the engine.
    private(set) var activeScriptId: String?

    /// Number of messages dispatched in the active run.
    private(set) var dispatchCount: Int = 0

    /// Last text dispatched — for diagnostic UIs.
    private(set) var lastDispatched: String?

    /// Timestamp of the last enqueued line (scripted or injected).
    /// Used by ContextualCoach to detect quiet stretches.
    private(set) var lastDispatchAt: Date?

    /// Ring buffer of the most recent dispatched lines. Sent to the
    /// /dynamic-line endpoint so the model knows what NOT to repeat.
    private(set) var recentDispatchedLines: [String] = []
    private let recentRingCapacity = 5

    // MARK: - Run state

    private var script: GeneratedScript?
    private var plan: RunPlan = .open
    private var firedMessageIds: Set<String> = []
    /// Per-message epoch counter for recurring triggers
    /// (distance.everyMeters and time.everySeconds).
    private var epochByMessageId: [String: Int] = [:]
    /// Per-message variant cursor — increments each time a looping
    /// message fires, used to rotate through the textVariants pool so
    /// per-km roasts never repeat back-to-back.
    private var variantCursorByMessageId: [String: Int] = [:]

    // MARK: - API

    func start(script: GeneratedScript, plan: RunPlan) {
        self.script = script
        self.plan = plan
        self.firedMessageIds.removeAll()
        self.epochByMessageId.removeAll()
        self.variantCursorByMessageId.removeAll()
        self.lastDispatchAt = nil
        self.dispatchCount = 0
        self.lastDispatched = nil
        self.recentDispatchedLines.removeAll()
        self.activeScriptId = script.scriptId
        self.isActive = true
        VoiceFeedbackQueue.shared.resetStats()
    }

    func stop() {
        self.isActive = false
        self.script = nil
        self.activeScriptId = nil
        self.firedMessageIds.removeAll()
        self.epochByMessageId.removeAll()
        self.variantCursorByMessageId.removeAll()
        self.lastDispatchAt = nil
        self.recentDispatchedLines.removeAll()
        VoiceFeedbackQueue.shared.stopAll()
    }

    /// Swap the active script mid-run. Used by the fast-start flow:
    /// the engine first runs against a stub script containing only the
    /// opener (generated quickly via /dynamic-line), then this is
    /// called once the full Sonnet-generated script arrives in the
    /// background so the per-km loop, halfway, finish, and surprise
    /// roasts all wire up.
    ///
    /// State is reset, but anything whose moment has already passed is
    /// pre-marked as fired so it doesn't replay. Looping triggers
    /// (everyMeters / everySeconds) are seeded to the current epoch so
    /// the next fire is at the next boundary, not back-fired for every
    /// missed km.
    func replaceScript(_ newScript: GeneratedScript, currentMetrics: LiveMetrics) {
        // Preserve a memory of "we already played the opener" by reusing
        // the recentDispatchedLines ring — the model uses it to avoid
        // repeating.
        self.script = newScript
        self.activeScriptId = newScript.scriptId
        self.firedMessageIds.removeAll()
        self.epochByMessageId.removeAll()
        self.variantCursorByMessageId.removeAll()

        let elapsed = currentMetrics.elapsed
        let distance = currentMetrics.distanceMeters

        for message in newScript.messages {
            let trigger = message.triggerSpec
            switch trigger.type {
            case .time:
                if let at = trigger.atSeconds, TimeInterval(at) <= elapsed {
                    firedMessageIds.insert(message.id)
                }
                if let every = trigger.everySeconds, every > 0 {
                    epochByMessageId[message.id] = Int(elapsed / TimeInterval(every))
                }
            case .distance:
                if let at = trigger.atMeters, at <= distance {
                    firedMessageIds.insert(message.id)
                }
                if let every = trigger.everyMeters, every > 0 {
                    epochByMessageId[message.id] = Int(distance / every)
                }
            case .halfway:
                if let total = plan.totalMeters, distance >= total / 2 {
                    firedMessageIds.insert(message.id)
                } else if let total = plan.totalSeconds, elapsed >= total / 2 {
                    firedMessageIds.insert(message.id)
                }
            case .nearFinish:
                if let total = plan.totalMeters,
                   let remaining = trigger.remainingMeters,
                   distance >= total - remaining {
                    firedMessageIds.insert(message.id)
                } else if let total = plan.totalSeconds,
                          let remainingSec = trigger.remainingSeconds,
                          elapsed >= total - TimeInterval(remainingSec) {
                    firedMessageIds.insert(message.id)
                }
            case .finish:
                if let total = plan.totalMeters, distance >= total {
                    firedMessageIds.insert(message.id)
                } else if let total = plan.totalSeconds, elapsed >= total {
                    firedMessageIds.insert(message.id)
                }
            }
        }
    }

    /// Inject a dynamically-generated line into the run. Called by the
    /// ContextualCoach when a reactive trigger (HR spike, pace drop,
    /// quiet stretch, lyric riff …) fires. Goes into the same queue as
    /// scripted lines at the priority the caller specifies; the queue
    /// arbitrates ordering and preemption.
    ///
    /// Returns `true` if the line was accepted by the queue. With the
    /// queue model this is almost always true — only dedup or muted
    /// state cause a drop, and the engine doesn't observe that result.
    @discardableResult
    func tryInject(
        text: String,
        source: String,
        priority: VoicePriority = .coaching,
        dedupKey: String? = nil,
        expiresAfter: TimeInterval? = nil,
        segmentId: UUID? = nil,
        decisionAt: Date? = nil
    ) -> Bool {
        guard isActive else { return false }
        Speaker.shared.speak(
            text,
            priority: priority,
            source: source,
            dedupKey: dedupKey,
            expiresAfter: expiresAfter,
            segmentId: segmentId,
            decisionAt: decisionAt
        )
        recordDispatch(text: text)
        return true
    }

    /// Evaluate every trigger against the current snapshot. Called by
    /// `LiveMetricsConsumer.ingest(_:)`. Cheap and side-effect-free
    /// when no message qualifies.
    func processTick(_ metrics: LiveMetrics) {
        guard isActive, let script else { return }

        for message in script.messages {
            if shouldFire(message: message, metrics: metrics) {
                dispatch(message, metrics: metrics)
                // One milestone per tick. The queue handles back-to-back
                // dispatches cleanly, but firing 5 milestones from a
                // single tick (e.g., catching up after a stall) would
                // overwhelm; one per second matches the metric cadence.
                return
            }
        }
    }

    // MARK: - Trigger evaluation

    private func shouldFire(message: ScriptMessage, metrics: LiveMetrics) -> Bool {
        let trigger = message.triggerSpec
        let elapsed = metrics.elapsed
        let distance = metrics.distanceMeters

        switch trigger.type {
        case .time:
            if let atSeconds = trigger.atSeconds {
                guard elapsed >= TimeInterval(atSeconds) else { return false }
                return passesPlayOnceGate(message)
            }
            if let everySeconds = trigger.everySeconds, everySeconds > 0 {
                let currentEpoch = Int(elapsed / TimeInterval(everySeconds))
                guard currentEpoch >= 1 else { return false }
                let lastEpoch = epochByMessageId[message.id] ?? 0
                if currentEpoch > lastEpoch {
                    epochByMessageId[message.id] = currentEpoch
                    return true
                }
                return false
            }
            return false

        case .distance:
            if let atMeters = trigger.atMeters {
                guard distance >= atMeters else { return false }
                return passesPlayOnceGate(message)
            }
            if let everyMeters = trigger.everyMeters, everyMeters > 0 {
                let currentEpoch = Int(distance / everyMeters)
                guard currentEpoch >= 1 else { return false }
                let lastEpoch = epochByMessageId[message.id] ?? 0
                if currentEpoch > lastEpoch {
                    epochByMessageId[message.id] = currentEpoch
                    return true
                }
                return false
            }
            return false

        case .halfway:
            // Distance plan → half distance; time plan → half elapsed.
            // Open plan → never fires.
            if let total = plan.totalMeters {
                guard distance >= total / 2 else { return false }
            } else if let total = plan.totalSeconds {
                guard elapsed >= total / 2 else { return false }
            } else {
                return false
            }
            return passesPlayOnceGate(message)

        case .nearFinish:
            // Distance plan + remainingMeters, OR time plan + remainingSeconds.
            if let total = plan.totalMeters,
               let remaining = trigger.remainingMeters {
                guard distance >= total - remaining else { return false }
                return passesPlayOnceGate(message)
            }
            if let total = plan.totalSeconds,
               let remainingSeconds = trigger.remainingSeconds {
                guard elapsed >= total - TimeInterval(remainingSeconds) else { return false }
                return passesPlayOnceGate(message)
            }
            return false

        case .finish:
            if let total = plan.totalMeters {
                guard distance >= total else { return false }
            } else if let total = plan.totalSeconds {
                guard elapsed >= total else { return false }
            } else {
                return false
            }
            return passesPlayOnceGate(message)
        }
    }

    private func passesPlayOnceGate(_ message: ScriptMessage) -> Bool {
        guard message.playOnce else { return true }
        if firedMessageIds.contains(message.id) { return false }
        firedMessageIds.insert(message.id)
        return true
    }

    // MARK: - Dispatch

    private func dispatch(_ message: ScriptMessage, metrics: LiveMetrics) {
        // For milestone-class triggers, prefix with a short, factual,
        // cacheable announcement so distance updates are always explicit
        // (e.g., "3 kilometres.") before the persona riff fires. The
        // announcement enters the queue first, then the riff right after;
        // both at .milestone priority so neither can be preempted by
        // lyric / pace banter.
        let announcement = MilestoneAnnouncement.text(
            for: message,
            plan: plan,
            distanceMeters: metrics.distanceMeters,
            elapsedSeconds: metrics.elapsed
        )
        if let announcement {
            Speaker.shared.speak(
                announcement,
                priority: .milestone,
                source: "script:announce:\(message.id)"
            )
        }

        // INTERTWINE the voices on per-km splits. The Director may assign
        // this km to Jessica (her share rising through the run — Ricky sets
        // the dark early tone, she's the vivid reward late). On her km, keep
        // the factual announcement above but skip Ricky's scripted riff and
        // let Jessica deliver the moment instead.
        if message.triggerSpec.type == .distance, RunDirector.shared.isActive {
            let km = max(1, Int((metrics.distanceMeters / 1000).rounded()))
            if RunDirector.shared.milestoneOwnerIsJessica(km: km) {
                RunEventLog.shared.record("milestone.owner", "jessica", data: ["km": String(km)])
                Conversation.shared.deliverMilestone(km: km, metrics: metrics)
                return
            }
        }

        let text = nextVariantText(for: message)
        RunEventLog.shared.record("script.dispatch", String(text.prefix(80)),
                                  data: ["trigger": message.triggerSpec.humanDescription])
        // ONLY true markers (km loop / halfway / near-finish / finish) get
        // .milestone — they must land on the marker, so they may preempt.
        // One-shot scheduled "surprise" flavor lines are just banter: keep
        // them .coaching so they NEVER cut off Jessica or a coach line (the
        // "cyclist" surprise was barging over Jessica because it was tagged
        // milestone). The factual announcement above is still milestone.
        let linePriority = Self.isMilestoneTrigger(message.triggerSpec) ? VoicePriority.milestone : .coaching
        // Tag with a segment id so Jessica's reaction (if she reacts) is
        // bound to this line as an atomic pair in the queue.
        let segment = UUID()
        Speaker.shared.speak(
            text,
            priority: linePriority,
            source: "script:\(message.id)",
            segmentId: segment
        )
        recordDispatch(text: text)
        // Second voice reacts to the roast (not the announcement). No-op
        // if Jessica is disabled or the Director says there's no room.
        Conversation.shared.rickySpoke(
            text: text,
            source: "script:\(message.id)",
            priority: linePriority,
            segmentId: segment,
            metrics: metrics
        )
    }

    /// True milestones (must land on the marker → may preempt). One-shot
    /// scheduled surprises are NOT milestones.
    private static func isMilestoneTrigger(_ t: TriggerSpec) -> Bool {
        switch t.type {
        case .halfway, .nearFinish, .finish: return true
        case .distance: return t.everyMeters != nil   // per-km loop = milestone; atMeters one-shot = surprise
        case .time: return t.everySeconds != nil       // interval = milestone; atSeconds one-shot = surprise
        }
    }

    private func recordDispatch(text: String) {
        lastDispatchAt = .now
        lastDispatched = text
        dispatchCount += 1
        recentDispatchedLines.append(text)
        if recentDispatchedLines.count > recentRingCapacity {
            recentDispatchedLines.removeFirst(recentDispatchedLines.count - recentRingCapacity)
        }
    }

    /// Pick the next rotation candidate for a message. For one-shot
    /// messages (no variants) this always returns `text`. For looping
    /// messages with variants, cycles through [text, *textVariants].
    private func nextVariantText(for message: ScriptMessage) -> String {
        let pool = message.rotationPool
        let cursor = variantCursorByMessageId[message.id] ?? 0
        variantCursorByMessageId[message.id] = cursor + 1
        return pool[cursor % pool.count]
    }
}
