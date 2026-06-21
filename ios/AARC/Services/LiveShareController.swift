import Foundation

/// LIVE in-run channel client — the runner-facing half of the "coach's coach".
/// When "Share live running data back home" is on AND the run is REAL (never a
/// test/sim run), this streams the run's events to the proxy and polls for a
/// line the agent ("home") pushes back, playing it in whatever distinct,
/// non-coach voice the agent specifies — so a voice that isn't Ricky or Jessica
/// is audibly "home". Entirely opt-in; does nothing unless the toggle is on.
@MainActor
final class LiveShareController {
    static let shared = LiveShareController()

    static let flagKey = "aarc.liveShare"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: flagKey) }

    private var runId: String?
    private var buffer: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private static func token() -> String? {
        (Bundle.main.object(forInfoDictionaryKey: "AARCLiveDeviceToken") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Begin streaming for a REAL run. No-op for test/sim runs or when off.
    func startIfEnabled(runId: UUID, isTest: Bool, startedAt: Date) {
        guard Self.enabled, !isTest, Self.token() != nil else { return }
        self.runId = runId.uuidString
        buffer = []
        let iso = ISO8601DateFormatter().string(from: startedAt)
        Task { await self.send("live/start", ["runId": runId.uuidString, "isTest": false, "startedAt": iso]) }
        flushTask?.cancel(); pollTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(12)); await self?.flush() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(10)); await self?.pollInject() }
        }
        NSLog("[live] sharing started for real run \(runId.uuidString.prefix(8))")
    }

    /// Mirror a run event into the live feed (called from RunEventLog.record).
    func append(type: String, detail: String, t: Double) {
        guard runId != nil else { return }
        buffer.append(["t": Int(t), "type": type, "detail": String(detail.prefix(220))])
        if buffer.count >= 40 { Task { await self.flush() } }
    }

    func end() {
        guard let rid = runId else { return }
        flushTask?.cancel(); pollTask?.cancel(); flushTask = nil; pollTask = nil
        let pending = buffer; buffer = []; runId = nil
        Task {
            if !pending.isEmpty { await self.send("live/events", ["runId": rid, "events": pending]) }
            await self.send("live/end", ["runId": rid])
            NSLog("[live] sharing ended")
        }
    }

    private func flush() async {
        guard let rid = runId, !buffer.isEmpty else { return }
        let events = buffer; buffer = []
        await send("live/events", ["runId": rid, "events": events])
    }

    /// Poll for a line the agent pushed; play it in the agent's chosen voice.
    private func pollInject() async {
        guard let rid = runId, let token = Self.token(),
              let url = URL(string: Config.apiBaseURL.appendingPathComponent("live/inject").absoluteString + "?runId=\(rid)")
        else { return }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = obj["line"] as? [String: Any],
              let text = line["text"] as? String,
              let voiceId = line["voiceId"] as? String, !text.isEmpty
        else { return }
        NSLog("[live] playing line from home (\(voiceId.prefix(8)))")
        Speaker.shared.speak(text, priority: .milestone, source: "home", voiceId: voiceId)
    }

    private func send(_ path: String, _ body: [String: Any]) async {
        guard let token = Self.token() else { return }
        var req = URLRequest(url: Config.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
