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

    enum UploadState: Equatable { case idle, uploading, delivered, failed }
    /// The latest recorded line's upload, so Siri can say the truth.
    private(set) var lastUpload: UploadState = .idle

    private static let pendingKey = "aarc.controlRoom.pending"
    private let defaults: UserDefaults
    private var retrying = false
    private var earTask: Task<Void, Never>?
    /// Just after he spoke: the in-run inject poll runs fast until then.
    private(set) var hotUntil = Date.distantPast
    /// The last time an answer from Control Room reached his ear.
    var lastAnswerAt = Date.distantPast
    /// No answer this long after a line: the server answers instead.
    /// 55, not 40: the desk's own answer often lands at 40 to 50 s, and the
    /// backup speaking first gave him two answers (18 Oct).
    static let watchdogSeconds: TimeInterval = 55
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
        let offRun = !LiveShareController.shared.downlinkAlive
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
                       elapsed: Double?, duration: Double, startedAt: Date = .now,
                       streamedText: String? = nil) async -> Outcome {
        if runId != nil {
            RunEventLog.shared.record("talkback.recorded", String(format: "%.0fs", duration), data: ["source": "siri"])
        }
        // `at` is when he started talking: the clip's place on the video timeline.
        let item = Pending(text: "", runId: runId, km: km, elapsed: elapsed, at: startedAt,
                           audioFile: file.lastPathComponent, clientId: clientId, duration: duration)
        // On the resend list BEFORE the upload: build 213's 111 s line was
        // cut off mid-upload by a suspension and, never having "failed", was
        // never queued. The proxy is idempotent on clientId, so a double
        // send is harmless.
        pending.append(item)
        let offRun = !LiveShareController.shared.downlinkAlive
        if offRun { holdAwake() }
        hotUntil = Date().addingTimeInterval(180)
        // Tier 1: the streamed transcript goes as text now; the audio follows
        // for the video and lands on the same row (idempotent on clientId).
        if let text = streamedText,
           let id = try? await AIClient.shared.agentSend(text, source: "voice", runId: runId, km: km,
                                                         elapsed: elapsed, clientId: clientId,
                                                         startedAt: startedAt, duration: duration) {
            lastUpload = .delivered
            if item.runId != nil { RunEventLog.shared.record("voice.said", text, data: ["source": "siri"]) }
            if offRun { listenForAnswer(after: id) }
            startWatchdog(clientId: clientId)
            Task { await self.retryPending() }
            return offRun ? .listening : .sent
        }
        if let id = await send(item) {
            pending.removeAll { $0.clientId == clientId }
            if id > 0 { startWatchdog(clientId: clientId) }
            if offRun { listenForAnswer(after: id); return .listening }
            return .sent
        }
        if offRun { releaseAwake() }
        return .queued
    }

    /// Race-day guard (founder, 2026-10-17): if the agent is busy or down and
    /// nothing answers within 55 s, the server answers in Home Base's voice
    /// from his live numbers. He is never left talking to nobody.
    private func startWatchdog(clientId: String) {
        let sentAt = Date()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.watchdogSeconds))
            guard let self, self.lastAnswerAt < sentAt else { return }
            let ctx = Self.runContext()
            guard let r = await AIClient.shared.agentAuto(clientId: clientId, runContext: ctx) else {
                self.diag("watchdog: no answer from the agent and the server fallback failed")
                return
            }
            guard self.lastAnswerAt < sentAt else { return }   // the agent got there meanwhile
            self.lastAnswerAt = .now
            Speaker.shared.speak(r.text, priority: .milestone, source: "home:watchdog",
                                 expiresAfter: 120, voiceId: RemoteTTS.homeVoiceId)
            self.diag("watchdog: \(r.already ? "replayed the agent's answer" : "server answered") after \(Int(Self.watchdogSeconds)) s")
        }
    }

    /// The same numbers a kilometre readout gets, when a run is on.
    private static func runContext() -> AIClient.DynamicLineContext? {
        let consumer = LiveMetricsConsumer.shared
        guard consumer.currentRunId != nil, let m = consumer.latest else { return nil }
        let plan = ScriptPreviewStore.shared.currentPlan
        return AIClient.DynamicLineContext(
            elapsedSeconds: m.elapsed,
            distanceMeters: m.distanceMeters,
            currentHR: m.currentHeartRate,
            avgHR: nil,
            currentPaceSecPerKm: m.currentPaceSecPerKm,
            avgPaceSecPerKm: m.avgPaceSecPerKm,
            planKind: plan.kind.rawValue,
            planDistanceKm: plan.distanceKm,
            planTimeMinutes: plan.timeMinutes,
            runType: consumer.pendingRunType.rawValue,
            stationarySeconds: nil,
            progressFraction: RunDirector.shared.progressFraction,
            place: PlaceContext.shared.llmInfo,
            ambient: PlaceContext.shared.ambientInfo
        )
    }

    /// Launch sweep: a recording file on disk that is on no list was cut off
    /// before it could be queued. Queue it now, so nothing he said is lost.
    func adoptOrphanRecordings() {
        let dir = ControlRoomRecorder.fileURL(UUID()).deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let known = Set(pending.compactMap(\.audioFile))
        var adopted = 0
        for name in names where name.hasSuffix(".m4a") && !name.contains(".seg") && !known.contains(name) {
            let url = dir.appendingPathComponent(name)
            let id = String(name.dropLast(4))
            guard UUID(uuidString: id) != nil, !ControlRoomRecorder.shared.isRecording,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date.now.timeIntervalSince(modified) > 120 else { continue }
            pending.append(Pending(text: "", runId: nil, km: nil, elapsed: nil, at: modified,
                                   audioFile: name, clientId: id, duration: nil))
            adopted += 1
        }
        if adopted > 0 { diag("talkback: found \(adopted) unsent recording(s) on the phone, sending") }
    }

    /// A Control Room line just became audible. Every Home Base line counts
    /// (answers, km readouts): they are all Control Room in the video.
    func heard(text: String, voiceId: String?) {
        guard let voiceId, voiceId == RemoteTTS.homeVoiceId else { return }
        let at = Date()
        let runId = LiveMetricsConsumer.shared.currentRunId?.uuidString
        Task { await AIClient.shared.agentHeard(text: text, voiceId: voiceId, at: at, runId: runId) }
    }

    /// A one-line diagnostic for the agent, on the thread as a terminal row.
    /// Fire and forget; the agent reads it in the ear loop.
    func diag(_ text: String) {
        Task { await diagNow(text) }
    }

    /// Awaited variant, for when the process may not live much longer.
    func diagNow(_ text: String) async {
        _ = try? await AIClient.shared.agentSend("[diag] " + text, source: "terminal")
    }

    // MARK: - Off-run answer

    /// In a run the answer comes through the run's inject poll; off-run there
    /// is no poll, so wait on the thread for the agent's spoken row.
    /// Lines the thread listener already spoke, so the inject poll (if it
    /// comes back) does not say them twice.
    private var played: [String] = []
    func alreadyPlayed(_ text: String) -> Bool { played.contains(text) }

    private func listenForAnswer(after id: Int) {
        guard id > 0 else { releaseAwake(); return }
        earTask?.cancel()
        earTask = Task { [weak self] in
            let deadline = Date.now.addingTimeInterval(Self.earWindow)
            var answered = false
            while !Task.isCancelled, Date.now < deadline, !answered {
                try? await Task.sleep(for: .seconds(1))
                // A live inject poll owns the reply.
                if LiveShareController.shared.downlinkAlive { break }
                guard let rows = try? await AIClient.shared.agentThread(since: id) else { continue }
                for row in rows where row.role == "agent" && row.source == "spoken" {
                    self?.played.append(row.text)
                    Speaker.shared.speak(row.text, priority: .milestone, source: "home",
                                         expiresAfter: 120, voiceId: RemoteTTS.homeVoiceId)
                    answered = true
                    self?.lastAnswerAt = .now
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
            self?.earTask = nil
        }
    }

    private func holdAwake() {
        guard !LiveShareController.shared.downlinkAlive else { return }
        AudioPlaybackManager.shared.beginSustained()
        BackgroundAudioKeepalive.shared.start()
    }

    private func releaseAwake() {
        // Never pull the audio out from under a live run.
        guard !LiveShareController.shared.downlinkAlive, !LiveMetricsConsumer.shared.isRunActive else { return }
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
            guard let id = await send(item) else { return }
            pending.removeAll { $0 == item }
            // A recorded line delivered late off-run still deserves a spoken
            // answer (17 Oct: the recovered 111 s line was answered in
            // silence). Only one listener at a time; the newest wins.
            if item.audioFile != nil, id > 0, earTask == nil,
               !LiveShareController.shared.downlinkAlive {
                holdAwake()
                listenForAnswer(after: id)
            }
        }
    }

    /// The thread row id on success.
    private func send(_ item: Pending) async -> Int? {
        do {
            let id: Int
            if let name = item.audioFile, let clientId = item.clientId {
                let url = ControlRoomRecorder.fileURL(UUID(uuidString: clientId) ?? UUID())
                guard url.lastPathComponent == name, FileManager.default.fileExists(atPath: url.path) else {
                    await diagNow("talkback upload: audio file missing for \(clientId.prefix(8))")
                    lastUpload = .failed
                    return -1   // audio gone: nothing left to send, let the queue move on
                }
                lastUpload = .uploading
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                // An empty file is a recording that never got audio: nothing to send.
                if size < 1024 {
                    try? FileManager.default.removeItem(at: url)
                    await diagNow("talkback: dropped an empty recording (\(size) bytes)")
                    lastUpload = .failed
                    return -1
                }
                let r: (id: Int, text: String)
                do {
                    r = try await AIClient.shared.agentVoice(file: url, clientId: clientId, runId: item.runId,
                                                             km: item.km, elapsed: item.elapsed,
                                                             duration: item.duration ?? 0,
                                                             startedAt: item.audioFile != nil ? item.at : nil)
                } catch {
                    lastUpload = .failed
                    diag("talkback upload failed (\(size / 1024) KB): \(error.localizedDescription); kept for retry")
                    throw error
                }
                lastUpload = .delivered
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
