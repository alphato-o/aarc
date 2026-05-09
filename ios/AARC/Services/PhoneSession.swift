import Foundation
import WatchConnectivity
import AARCKit

/// iOS-side wrapper around `WCSession`. Phase 0 ran the hello smoke test;
/// §1.2 wires this up as the live-metrics ingestion path: the watch sends
/// `LiveMetrics` 1 Hz via `sendMessageData` (best-effort) and workout
/// state events via `transferUserInfo` (queued + guaranteed).
///
/// Concurrency notes:
/// - Class is `@MainActor` so SwiftUI can read its `@Observable` state.
/// - Delegate methods are `nonisolated` because WatchConnectivity invokes
///   them on a background queue. They capture values into locals before
///   hopping to MainActor for state mutation and ingest.
@Observable
@MainActor
final class PhoneSession: NSObject {
    static let shared = PhoneSession()

    var isReachable: Bool = false
    var isPaired: Bool = false
    var activationState: WCSessionActivationState = .notActivated
    var lastInboundText: String?

    private let session: WCSession?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func sendHello(text: String = "hello from phone") {
        guard let session,
              session.activationState == .activated,
              session.isReachable else { return }
        let message = WCMessage.hello(text: text)
        guard let data = try? encoder.encode(message) else { return }
        session.sendMessageData(data, replyHandler: nil) { _ in }
    }

    /// Send a state event to the watch. Uses transferUserInfo so the
    /// message is queued and guaranteed to deliver, even if the watch
    /// app isn't reachable at the instant of send.
    func sendStateEvent(_ event: WCMessage) {
        guard let session, session.activationState == .activated else { return }
        guard let data = try? encoder.encode(event) else { return }
        session.transferUserInfo([Self.userInfoMessageKey: data])
    }

    /// Decode + route a WCMessage inbound from the watch.
    private func route(_ message: WCMessage) {
        switch message {
        case .hello(let text):
            self.lastInboundText = text

        case .liveMetrics(let metrics):
            LiveMetricsConsumer.shared.ingest(metrics)

        case .workoutStarted(let runId, let startedAt):
            LiveMetricsConsumer.shared.ingestStarted(runId: runId, startedAt: startedAt)

        case .workoutPaused:
            LiveMetricsConsumer.shared.ingestPaused()

        case .workoutResumed:
            LiveMetricsConsumer.shared.ingestResumed()

        case .workoutEnded(let workoutUUID):
            LiveMetricsConsumer.shared.ingestEnded(workoutUUID: workoutUUID)

        case .prepareWorkout(let runId, let runType, let personalityId):
            // Watch user just hit Start. Generate a script for them.
            Task {
                await RunOrchestrator.shared.handlePrepareFromWatch(
                    runId: runId,
                    runType: runType,
                    personalityId: personalityId
                )
            }

        // Outbound-only on phone side; ignore if echoed somehow.
        case .startWorkout, .endWorkout, .hapticCue, .companionMessageDispatched,
             .scriptReady, .scriptFailed:
            break
        }
    }
}

extension PhoneSession: @preconcurrency WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let isPaired = session.isPaired
        let isReachable = session.isReachable
        Task { @MainActor in
            self.activationState = activationState
            self.isPaired = isPaired
            self.isReachable = isReachable
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in self.isReachable = isReachable }
    }

    /// Live-metrics path (1 Hz, best-effort).
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            guard let message = try? self.decoder.decode(WCMessage.self, from: messageData) else { return }
            self.route(message)
        }
    }

    /// State-event path (queued, guaranteed delivery).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Self.userInfoMessageKey] as? Data else { return }
        Task { @MainActor in
            guard let message = try? self.decoder.decode(WCMessage.self, from: data) else { return }
            self.route(message)
        }
    }

    /// Key shared with the watch side for envelope wrapping.
    nonisolated static let userInfoMessageKey = "wc.message"
}
