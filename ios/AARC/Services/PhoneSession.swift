import Foundation
import WatchConnectivity
import AARCKit

/// iOS-side wrapper around `WCSession`. Phase 0 establishes the session and
/// supports a smoke-test `hello` round-trip; Phase 1 wires this to ScriptEngine.
///
/// Concurrency notes:
/// - Class is `@MainActor` so SwiftUI views can read its `@Observable` state directly.
/// - Delegate methods are explicitly `nonisolated` because WatchConnectivity invokes
///   them on a background queue. They capture values into locals before hopping to
///   MainActor to mutate state.
/// - State is sourced from the activation delegate callback, never read synchronously
///   right after `session.activate()`.
@Observable
@MainActor
final class PhoneSession: NSObject {
    var isReachable: Bool = false
    var isPaired: Bool = false
    var activationState: WCSessionActivationState = .notActivated
    var lastInboundText: String?

    private let session: WCSession?

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
        // isPaired / isReachable / activationState come from the delegate callback.
    }

    func sendHello(text: String = "hello from phone") {
        guard let session,
              session.activationState == .activated,
              session.isReachable else { return }
        let message = WCMessage.hello(text: text)
        guard let data = try? JSONEncoder().encode(message) else { return }
        session.sendMessageData(data, replyHandler: nil) { _ in }
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
        // Per Apple guidance, reactivate on iOS so the next paired watch can connect.
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in self.isReachable = isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let message = try? JSONDecoder().decode(WCMessage.self, from: messageData) else { return }
        if case .hello(let text) = message {
            Task { @MainActor in self.lastInboundText = text }
        }
    }
}
