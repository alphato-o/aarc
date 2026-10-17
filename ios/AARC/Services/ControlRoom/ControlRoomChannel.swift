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

    /// `.listening`: sent with no run on; the app stays awake and speaks the
    /// answer when it comes.
    enum Outcome: Equatable { case sent, listening, queued }

    struct Pending: Codable, Equatable {
        let text: String
        let runId: String?
        let km: Double?
        let elapsed: Double?
        let at: Date
        /// Set for a recorded line: the audio file name under Documents/talkback.
        var audioFile: String? = nil
        var clientId: String? = nil
        var duration: Double? = nil
    }

    private static let pendingKey = "aarc.controlRoom.pending"
    private let defaults: UserDefaults
    private var retrying = false
    private var earTask: Task<Void, Never>?
    /// How long to stay awake for an answer off-run. The agent answers from
    /// the ear loop (5 s poll) plus thinking time; three minutes is generous.
    static let earWindow: TimeInterval = 180
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
        // Off-run (founder, 2026-10-17: "even if AARC is not running I want to
        // hear your response"): start the silent keepalive BEFORE the network
        // call, while Siri still has the app executing, so iOS keeps it awake
        // in the background until the answer is spoken.
        let offRun = runId == nil
        if offRun { holdAwake() }
        if let id = await send(item) {
            if offRun { listenForAnswer(after: id); return .listening }
            return .sent
        }
        if offRun { releaseAwake() }
        pending.append(item)
        return .queued
    }

    /// A line recorded by ControlRoomRecorder. The audio is kept until the
    /// proxy has transcribed it; a resend is idempotent on clientId.
    func sendRecording(file: URL, clientId: String, runId: String?, km: Double?,
                       elapsed: Double?, duration: Double) async -> Outcome {
        if runId != nil {
            RunEventLog.shared.record("talkback.recorded", String(format: "%.0fs", duration), data: ["source": "siri"])
        }
        let item = Pending(text: "", runId: runId, km: km, elapsed: elapsed, at: .now,
                           audioFile: file.lastPathComponent, clientId: clientId, duration: duration)
        let offRun = runId == nil
        if offRun { holdAwake() }
        if let id = await send(item) {
            if offRun { listenForAnswer(after: id); return .listening }
            return .sent
        }
        if offRun { releaseAwake() }
        pending.append(item)
        return .queued
    }

    // MARK: - Off-run answer

    /// In a run the answer comes through the run's inject poll; off-run there
    /// is no poll, so wait on the thread for the agent's spoken row.
    private func listenForAnswer(after id: Int) {
        guard id > 0 else { releaseAwake(); return }
        earTask?.cancel()
        earTask = Task { [weak self] in
            let deadline = Date.now.addingTimeInterval(Self.earWindow)
            var answered = false
            while !Task.isCancelled, Date.now < deadline, !answered {
                try? await Task.sleep(for: .seconds(3))
                // A run that started meanwhile owns the reply via inject.
                if LiveMetricsConsumer.shared.currentRunId != nil { break }
                guard let rows = try? await AIClient.shared.agentThread(since: id) else { continue }
                for row in rows where row.role == "agent" && row.source == "spoken" {
                    Speaker.shared.speak(row.text, priority: .milestone, source: "home",
                                         expiresAfter: 120, voiceId: RemoteTTS.homeVoiceId)
                    answered = true
                }
            }
            if answered {
                // Stay awake until the line has actually played.
                let playDeadline = Date.now.addingTimeInterval(90)
                try? await Task.sleep(for: .seconds(2))
                while Date.now < playDeadline,
                      VoiceFeedbackQueue.shared.currentlyPlaying != nil || !VoiceFeedbackQueue.shared.pending.isEmpty {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            self?.releaseAwake()
        }
    }

    private func holdAwake() {
        guard LiveMetricsConsumer.shared.currentRunId == nil else { return }
        AudioPlaybackManager.shared.beginSustained()
        BackgroundAudioKeepalive.shared.start()
    }

    private func releaseAwake() {
        // Never pull the audio out from under a run that started meanwhile.
        guard LiveMetricsConsumer.shared.currentRunId == nil else { return }
        BackgroundAudioKeepalive.shared.stop()
        AudioPlaybackManager.shared.endSustained()
    }

    /// Resend whatever is queued. Called from the in-run poll tick and on
    /// foreground, so a line said in a dead spot arrives when signal does.
    func retryPending() async {
        guard !retrying, !pending.isEmpty else { return }
        retrying = true
        defer { retrying = false }
        while let item = pending.first {
            guard await send(item) != nil else { return }
            pending.removeFirst()
        }
    }

    /// The thread row id on success.
    private func send(_ item: Pending) async -> Int? {
        do {
            let id: Int
            if let name = item.audioFile, let clientId = item.clientId {
                let url = ControlRoomRecorder.fileURL(UUID(uuidString: clientId) ?? UUID())
                guard url.lastPathComponent == name, FileManager.default.fileExists(atPath: url.path) else {
                    return -1   // audio gone: nothing left to send, let the queue move on
                }
                let r = try await AIClient.shared.agentVoice(file: url, clientId: clientId, runId: item.runId,
                                                             km: item.km, elapsed: item.elapsed,
                                                             duration: item.duration ?? 0)
                id = r.id
                if item.runId != nil { RunEventLog.shared.record("voice.said", r.text, data: ["source": "siri"]) }
                try? FileManager.default.removeItem(at: url)
            } else {
                id = try await AIClient.shared.agentSend(item.text, source: "voice", runId: item.runId,
                                                         km: item.km, elapsed: item.elapsed)
            }
            lastSent = .now
            lastError = nil
            return id
        } catch {
            lastError = error.localizedDescription
            NSLog("[controlroom] send failed, queued: \(error.localizedDescription)")
            return nil
        }
    }
}
