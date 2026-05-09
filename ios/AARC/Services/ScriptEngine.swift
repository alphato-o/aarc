import Foundation
import Observation
import AARCKit

/// The "brain" that turns the watch's 1 Hz `LiveMetrics` stream into
/// spoken lines at the right moments. Subscribes to whatever script is
/// currently active, evaluates each message's `triggerSpec` against
/// every metric tick, and dispatches matching messages to
/// `Speaker.shared.speak()`.
///
/// Lifecycle:
/// - `start(script:plannedDistanceMeters:)` — called when the watch
///   sends `workoutStarted`; resets fired-message tracking.
/// - `processTick(_:)` — called for every `LiveMetrics` snapshot.
/// - `stop()` — called when the watch sends `workoutEnded`.
///
/// Idempotency:
/// - `playOnce: true` messages fire at most once per run.
/// - `playOnce: false` messages fire at most once per "epoch" (e.g.
///   per-km loop fires once per km crossed).
/// - A flat cooldown prevents spam if multiple triggers fire within a
///   short window.
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

    /// Minimum gap between two dispatched lines, in seconds. Prevents
    /// spam when several triggers happen to match in the same second
    /// (e.g. surprise + per-km landing on the same metric tick).
    private let cooldown: TimeInterval = 10

    // MARK: - Run state

    private var script: GeneratedScript?
    private var plannedDistanceMeters: Double = 0
    private var firedMessageIds: Set<String> = []
    private var lastFiredKmByMessageId: [String: Int] = [:]
    private var lastDispatchAt: Date?

    // MARK: - API

    func start(script: GeneratedScript, plannedDistanceMeters: Double) {
        self.script = script
        self.plannedDistanceMeters = plannedDistanceMeters
        self.firedMessageIds.removeAll()
        self.lastFiredKmByMessageId.removeAll()
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
        self.lastFiredKmByMessageId.removeAll()
        self.lastDispatchAt = nil
    }

    /// Evaluate every trigger against the current snapshot. Called by
    /// `LiveMetricsConsumer.ingest(_:)`. Cheap and side-effect-free
    /// when no message qualifies.
    func processTick(_ metrics: LiveMetrics) {
        guard isActive, let script else { return }

        // Cooldown gate — if we just spoke, don't speak again yet.
        if let last = lastDispatchAt,
           Date().timeIntervalSince(last) < cooldown {
            return
        }

        for message in script.messages {
            if shouldFire(message: message, metrics: metrics) {
                dispatch(message)
                // One dispatch per tick. Other matching messages will
                // get their turn on subsequent ticks once cooldown
                // clears.
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
            guard let atSeconds = trigger.atSeconds else { return false }
            guard elapsed >= TimeInterval(atSeconds) else { return false }
            return passesPlayOnceGate(message)

        case .distance:
            if let atMeters = trigger.atMeters {
                guard distance >= atMeters else { return false }
                return passesPlayOnceGate(message)
            }
            if let everyMeters = trigger.everyMeters, everyMeters > 0 {
                let currentEpoch = Int(distance / everyMeters)
                guard currentEpoch >= 1 else { return false }
                let lastEpoch = lastFiredKmByMessageId[message.id] ?? 0
                if currentEpoch > lastEpoch {
                    lastFiredKmByMessageId[message.id] = currentEpoch
                    return true
                }
                return false
            }
            return false

        case .halfway:
            guard plannedDistanceMeters > 0 else { return false }
            guard distance >= plannedDistanceMeters / 2 else { return false }
            return passesPlayOnceGate(message)

        case .nearFinish:
            guard plannedDistanceMeters > 0,
                  let remaining = trigger.remainingMeters else { return false }
            guard distance >= plannedDistanceMeters - remaining else { return false }
            return passesPlayOnceGate(message)

        case .finish:
            guard plannedDistanceMeters > 0 else { return false }
            guard distance >= plannedDistanceMeters else { return false }
            return passesPlayOnceGate(message)
        }
    }

    /// For messages with `playOnce: true`, fire at most once per run.
    /// `playOnce: false` messages bypass this gate (their per-trigger
    /// state is tracked separately, e.g. lastFiredKm for
    /// `distance.everyMeters`).
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
