import Foundation
import Observation

/// Talk-back during a run (founder, 2026-10-17): "the last chunk of feature
/// ... to graduate 1.0". He cannot press buttons or pull the phone out, but a
/// long press on the Powerbeats is Siri, so the "Tell Control Room" shortcut
/// dictates a line and hands it here. Same channel as the Home Base terminal:
/// the line lands on the agent thread, the daemon wakes the agent, and the
/// answer comes back through the run's inject queue in Kristen's voice.
///
/// Every mode, not only race mode: the thread is just text, so nothing about
/// the run leaks that he did not say himself.
@Observable
@MainActor
final class ControlRoomChannel {
    static let shared = ControlRoomChannel()

    enum Outcome: Equatable { case sent, queued }

    struct Pending: Codable, Equatable {
        let text: String
        let runId: String?
        let km: Double?
        let elapsed: Double?
        let at: Date
    }

    private static let pendingKey = "aarc.controlRoom.pending"
    private let defaults: UserDefaults
    private var retrying = false
    private(set) var lastSent: Date?
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Lines that could not reach the proxy yet (Tianjin start has no signal
    /// for the first half hour). Oldest first; resent in order.
    var pending: [Pending] {
        get {
            guard let data = defaults.data(forKey: Self.pendingKey),
                  let items = try? JSONDecoder().decode([Pending].self, from: data) else { return [] }
            return items
        }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.pendingKey) }
            else if let data = try? JSONEncoder().encode(newValue.suffix(50)) { defaults.set(data, forKey: Self.pendingKey) }
        }
    }

    /// What he said, with where he was when he said it.
    func say(_ text: String) async -> Outcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .sent }
        let consumer = LiveMetricsConsumer.shared
        let runId = consumer.currentRunId?.uuidString
        let km = consumer.latest.map { $0.distanceMeters / 1000 }
        let elapsed = consumer.latest?.elapsed
        if runId != nil {
            // Mirrors into the live uplink when sharing or racing, so the
            // Control Room page ticker shows the line next to his position.
            RunEventLog.shared.record("voice.said", text, data: ["source": "siri"])
        }
        let item = Pending(text: text, runId: runId, km: km, elapsed: elapsed, at: .now)
        if await send(item) { return .sent }
        pending.append(item)
        return .queued
    }

    /// Resend whatever is queued. Called from the in-run poll tick and on
    /// foreground, so a line said in a dead spot arrives when signal does.
    func retryPending() async {
        guard !retrying, !pending.isEmpty else { return }
        retrying = true
        defer { retrying = false }
        while let item = pending.first {
            guard await send(item) else { return }
            pending.removeFirst()
        }
    }

    private func send(_ item: Pending) async -> Bool {
        do {
            _ = try await AIClient.shared.agentSend(item.text, source: "voice", runId: item.runId,
                                                     km: item.km, elapsed: item.elapsed)
            lastSent = .now
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            NSLog("[controlroom] send failed, queued: \(error.localizedDescription)")
            return false
        }
    }
}
