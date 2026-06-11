import Foundation
import os
import AARCKit

/// Severity for `CrashReporter.captureMessage`. Mirrors Sentry's levels.
enum CrashReportLevel: String, Sendable {
    case fatal, error, warning, info, debug
}

/// Thin error-reporting facade — NOT the sentry-cocoa SDK (deliberate:
/// whether to take that dependency is a separate decision; until it lands
/// this covers handled errors only, no crash handlers).
///
/// Every capture does three things:
///  1. os.Logger error log (always)
///  2. forwards to the in-app run event log via `eventSink` (when wired)
///  3. POSTs a minimal Sentry envelope IFF UserDefaults "aarc.sentry.dsn"
///     holds a non-empty DSN — otherwise fully inert on the network
///
/// Callable from any isolation context (nonisolated statics, all state
/// behind a lock); fire-and-forget, never throws, never blocks.
enum CrashReporter {
    private static let log = Logger(subsystem: "club.aarun.AARC", category: "CrashReporter")

    /// UserDefaults key the Settings diagnostics field writes the DSN to.
    static let dsnDefaultsKey = "aarc.sentry.dsn"

    // MARK: - RunEventLog bridge

    /// Wiring point for RunEventLog (built separately) so this file has no
    /// compile-time dependency on it. Orchestrator: at app startup set
    ///     CrashReporter.setEventSink { kind, message in
    ///         RunEventLog.shared.record(kind, message)
    ///     }
    /// (adapt to RunEventLog's actual API; hop to @MainActor inside the
    /// closure if RunEventLog is main-actor isolated).
    private static let sink = OSAllocatedUnfairLock<(@Sendable (_ kind: String, _ message: String) -> Void)?>(initialState: nil)

    static func setEventSink(_ newSink: (@Sendable (_ kind: String, _ message: String) -> Void)?) {
        sink.withLock { $0 = newSink }
    }

    // MARK: - Public API

    static func capture(error: Error, context: [String: String] = [:]) {
        let typeName = String(describing: type(of: error))
        let message = String(describing: error)
        log.error("captured \(typeName, privacy: .public): \(message, privacy: .public) context=\(context.description, privacy: .public)")
        sink.withLock { $0 }?("error", "\(typeName): \(message)")

        var extra = context
        extra["localizedDescription"] = error.localizedDescription
        postEvent([
            "level": "error",
            "exception": [
                "values": [["type": typeName, "value": message]],
            ],
            "extra": extra,
        ])
    }

    static func captureMessage(
        _ message: String,
        level: CrashReportLevel = .error,
        context: [String: String] = [:]
    ) {
        log.error("[\(level.rawValue, privacy: .public)] \(message, privacy: .public) context=\(context.description, privacy: .public)")
        sink.withLock { $0 }?("error", message)

        postEvent([
            "level": level.rawValue,
            "message": ["formatted": message],
            "extra": context,
        ])
    }

    // MARK: - Sentry envelope transport

    private struct ParsedDSN {
        let publicKey: String
        let host: String
        let projectId: String

        /// https://KEY@oNNN.ingest.sentry.io/PROJECT
        init?(_ dsn: String) {
            guard let components = URLComponents(string: dsn),
                  let user = components.user, !user.isEmpty,
                  let host = components.host, !host.isEmpty
            else { return nil }
            let project = components.path.replacingOccurrences(of: "/", with: "")
            guard !project.isEmpty else { return nil }
            self.publicKey = user
            self.host = host
            self.projectId = project
        }
    }

    private static func postEvent(_ body: [String: Any]) {
        guard let dsnString = UserDefaults.standard.string(forKey: dsnDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !dsnString.isEmpty,
              let dsn = ParsedDSN(dsnString)
        else { return }

        let eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sentAt = ISO8601DateFormatter().string(from: Date())

        var event: [String: Any] = [
            "event_id": eventId,
            "timestamp": sentAt,
            "platform": "cocoa",
            "release": AppVersion.build,
            "environment": "dev",
            "tags": ["service": "aarc-ios"],
            "sdk": ["name": "aarc.urlsession-envelope", "version": "1.0.0"],
        ]
        event.merge(body) { _, new in new }

        guard
            let headerData = try? JSONSerialization.data(withJSONObject: [
                "event_id": eventId, "sent_at": sentAt, "dsn": dsnString,
            ]),
            let itemHeaderData = try? JSONSerialization.data(withJSONObject: ["type": "event"]),
            let eventData = try? JSONSerialization.data(withJSONObject: event),
            let url = URL(string: "https://\(dsn.host)/api/\(dsn.projectId)/envelope/")
        else { return }

        var envelope = Data()
        let newline = Data("\n".utf8)
        envelope.append(headerData)
        envelope.append(newline)
        envelope.append(itemHeaderData)
        envelope.append(newline)
        envelope.append(eventData)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = envelope
        request.timeoutInterval = 10
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Sentry sentry_version=7, sentry_client=aarc-ios/1.0, sentry_key=\(dsn.publicKey)",
            forHTTPHeaderField: "X-Sentry-Auth"
        )

        // Fire-and-forget: reporting must never stall or crash the caller.
        URLSession.shared.dataTask(with: request).resume()
    }
}
