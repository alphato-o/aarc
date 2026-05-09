import Foundation
import Observation
import AARCKit

/// The "brain" that turns the watch's 1 Hz `LiveMetrics` stream into
/// spoken lines at the right moments. Subscribes to whatever script is
/// currently active, evaluates each message's `triggerSpec` against
/// every metric tick, and dispatches matching messages to
/// `Speaker.shared.speak()`.
///
/// Plan-aware: `halfway`, `near_finish`, and `finish` triggers
/// evaluate against distance for `.distance` plans, against elapsed
/// time for `.time` plans, and never fire for `.open` plans (the
/// model is instructed not to emit them in that case anyway).
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

    // MARK: - Configuration

    /// Minimum gap between two dispatched lines, in seconds.
    private let cooldown: TimeInterval = 10

    // MARK: - Run state

    private var script: GeneratedScript?
    private var plan: RunPlan = .open
    private var firedMessageIds: Set<String> = []
    /// Per-message epoch counter for recurring triggers
    /// (distance.everyMeters and time.everySeconds).
    private var epochByMessageId: [String: Int] = [:]
    private var lastDispatchAt: Date?

    // MARK: - API

    func start(script: GeneratedScript, plan: RunPlan) {
        self.script = script
        self.plan = plan
        self.firedMessageIds.removeAll()
        self.epochByMessageId.removeAll()
        self.lastDispatchAt = nil
        self.dispatchCount = 0
        self.lastDispatched = nil
        self.activeScriptId = script.scriptId
        self.isActive = true
    }

    func stop() {
        self.isActive = false
        self.script = nil
        self.activeScriptId = nil
        self.firedMessageIds.removeAll()
        self.epochByMessageId.removeAll()
        self.lastDispatchAt = nil
    }

    /// Evaluate every trigger against the current snapshot. Called by
    /// `LiveMetricsConsumer.ingest(_:)`. Cheap and side-effect-free
    /// when no message qualifies.
    func processTick(_ metrics: LiveMetrics) {
        guard isActive, let script else { return }

        if let last = lastDispatchAt,
           Date().timeIntervalSince(last) < cooldown {
            return
        }

        for message in script.messages {
            if shouldFire(message: message, metrics: metrics) {
                dispatch(message)
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

    private func dispatch(_ message: ScriptMessage) {
        Speaker.shared.speak(message.text)
        lastDispatchAt = .now
        lastDispatched = message.text
        dispatchCount += 1
    }
}
