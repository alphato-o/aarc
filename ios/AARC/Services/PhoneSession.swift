import Foundation
import WatchConnectivity
import AARCKit

/// iOS-side wrapper around `WCSession`. Phase 0 establishes the session and
/// supports a smoke-test `hello` round-trip; Phase 1 wires this to ScriptEngine.
@Observable
@MainActor
final class PhoneSession: NSObject {
    var isReachable: Bool = false
    var isPaired: Bool = false
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
        isPaired = session.isPaired
        isReachable = session.isReachable
    }

    func sendHello(text: String = "hello from phone") {
        guard let session, session.isReachable else { return }
        let msg = WCMessage.hello(text: text)
        guard let data = try? JSONEncoder().encode(msg) else { return }
        session.sendMessageData(data, replyHandler: nil) { _ in }
    }

    private func handle(messageData: Data) {
        guard let message = try? JSONDecoder().decode(WCMessage.self, from: messageData) else { return }
        if case .hello(let text) = message {
            Task { @MainActor in self.lastInboundText = text }
        }
    }
}

extension PhoneSession: @preconcurrency WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isPaired = session.isPaired
            self.isReachable = session.isReachable
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handle(messageData: messageData)
    }
}
