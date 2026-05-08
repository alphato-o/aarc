import Foundation
import WatchConnectivity
import AARCKit

/// watchOS-side wrapper around `WCSession`. Same concurrency contract as
/// PhoneSession: class is `@MainActor`, delegate methods are `nonisolated`
/// because WatchConnectivity invokes them on a background queue, and state
/// is sourced from the activation callback rather than read synchronously.
@Observable
@MainActor
final class WatchSession: NSObject {
    var isReachable: Bool = false
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
        guard let message = try? JSONDecoder().decode(WCMessage.self, from: messageData) else { return }
        if case .hello(let text) = message {
            Task { @MainActor in self.lastInboundText = text }
        }
    }
}
