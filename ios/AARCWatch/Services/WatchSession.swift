import Foundation
import WatchConnectivity
import AARCKit

@Observable
@MainActor
final class WatchSession: NSObject {
    var isReachable: Bool = false
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
        isReachable = session.isReachable
    }

    private func handle(messageData: Data) {
        guard let message = try? JSONDecoder().decode(WCMessage.self, from: messageData) else { return }
        if case .hello(let text) = message {
            Task { @MainActor in self.lastInboundText = text }
        }
    }
}

extension WatchSession: @preconcurrency WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handle(messageData: messageData)
    }
}
