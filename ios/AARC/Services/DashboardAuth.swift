import Foundation
import Observation
import os

/// Approves dashboard QR sign-in codes via the `aarc://` deep link.
///
/// Flow: the web dashboard login page (api.aarun.club/dash) shows a QR
/// encoding `aarc://dash-auth?code=XXXX`. Scanning it with the iPhone
/// camera opens this app, AARCApp's `.onOpenURL` calls `handle(url:)`,
/// and we POST the code to `/dash/auth/approve` with the shared device
/// secret. The browser is polling the same code and picks up its session
/// cookie on the next poll.
///
/// The device secret lives in Info.plist under `AARCDeviceToken` and must
/// equal the Worker's `DEVICE_TOKEN` secret. Never ship a real API key in
/// the app — this token only gates access to *our own* run data.
@MainActor
@Observable
final class DashboardAuth {
    static let shared = DashboardAuth()

    struct AuthEvent: Equatable, Sendable {
        let success: Bool
        let message: String
        let at: Date
    }

    /// Most recent approval attempt, for a toast/banner in the UI.
    private(set) var lastResult: AuthEvent?
    private(set) var isApproving = false

    private let logger = Logger(subsystem: "club.aarun.AARC", category: "DashboardAuth")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Entry point for `.onOpenURL`. Returns true if the URL was an
    /// aarc://dash-auth link (handled here), false if the caller should
    /// route it elsewhere.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "aarc" else { return false }
        // aarc://dash-auth?code=... -> host is "dash-auth"
        guard url.host?.lowercased() == "dash-auth" else { return false }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let raw = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            report(success: false, message: "Sign-in link is missing a code.")
            return true
        }

        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (8...64).contains(code.count),
              code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            report(success: false, message: "Sign-in code looks malformed.")
            return true
        }

        guard let token = Self.deviceToken() else {
            logger.error("AARCDeviceToken missing from Info.plist — cannot approve dash sign-in")
            report(success: false, message: "Device token not configured in this build.")
            return true
        }

        logger.info("approving dash sign-in code \(code.prefix(4), privacy: .public)…")
        isApproving = true
        Task { [weak self] in
            await self?.approve(code: code, token: token)
        }
        return true
    }

    private func approve(code: String, token: String) async {
        defer { isApproving = false }

        var request = URLRequest(url: Config.apiBaseURL.appendingPathComponent("dash/auth/approve"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        do {
            request.httpBody = try JSONEncoder().encode(["code": code])
        } catch {
            report(success: false, message: "Could not encode approval request.")
            return
        }

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200...299:
                logger.info("dash sign-in approved")
                report(success: true, message: "Dashboard signed in.")
            case 401:
                logger.error("dash approve rejected: device token mismatch")
                report(success: false, message: "Device token rejected — check AARCDeviceToken vs DEVICE_TOKEN.")
            case 404:
                report(success: false, message: "Code expired — reload the dashboard page and rescan.")
            default:
                logger.error("dash approve failed: HTTP \(status)")
                report(success: false, message: "Sign-in failed (HTTP \(status)).")
            }
        } catch {
            logger.error("dash approve network error: \(error.localizedDescription, privacy: .public)")
            report(success: false, message: "Network error — try scanning again.")
        }
    }

    private func report(success: Bool, message: String) {
        lastResult = AuthEvent(success: success, message: message, at: Date())
    }

    private static func deviceToken() -> String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "AARCDeviceToken") as? String,
              !token.isEmpty else { return nil }
        return token
    }
}
