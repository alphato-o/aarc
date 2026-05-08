import Foundation
import WatchConnectivity
import AARCKit

/// watchOS-side wrapper around `WCSession`. §1.2 makes this the
/// outbound channel for `LiveMetrics` (1 Hz, best-effort) and workout
/// state events (queued, guaranteed).
@Observable
@MainActor
final class WatchSession: NSObject {
    static let shared = WatchSession()

    var isReachable: Bool = false
    var activationState: WCSessionActivationState = .notActivated
    var lastInboundText: String?

    private let session: WCSession?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Shared envelope key with the iPhone side. Wraps the encoded
    /// WCMessage payload inside the userInfo dictionary that
    /// `transferUserInfo` accepts.
    nonisolated static let userInfoMessageKey = "wc.message"

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound

    /// 1 Hz live metrics. Best-effort — drops if phone unreachable.
    /// The watch itself remains the source of truth via HealthKit, so
    /// drops are acceptable.
    func sendLiveMetrics(_ metrics: LiveMetrics) {
        guard let session,
              session.activationState == .activated,
              session.isReachable else { return }
        let message = WCMessage.liveMetrics(metrics)
        guard let data = try? encoder.encode(message) else { return }
        session.sendMessageData(data, replyHandler: nil) { _ in
            // Silent on failure — next tick will retry; nothing to recover.
        }
    }

    /// Workout state events: workoutStarted / paused / resumed / ended.
    /// Uses `transferUserInfo` so the message is queued and delivered
    /// when the phone next becomes reachable, even if the phone is
    /// asleep at the moment of send.
    func sendStateEvent(_ event: WCMessage) {
        guard let session, session.activationState == .activated else { return }
        guard let data = try? encoder.encode(event) else { return }
        session.transferUserInfo([Self.userInfoMessageKey: data])
    }
}

extension WatchSession: @preconcurrency WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.activationState = activationState
            self.isReachable = isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in self.isReachable = isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            guard let message = try? self.decoder.decode(WCMessage.self, from: messageData) else { return }
            if case .hello(let text) = message {
                self.lastInboundText = text
            }
            // §1.2 only wires the watch → phone direction in earnest.
            // Phone → Watch (e.g., startWorkout, hapticCue) lands in §4.
        }
    }
}
