import Foundation
import UIKit

/// LIVE in-run channel client — the runner-facing half of the "coach's coach".
/// When "Share live running data back home" is on AND the run is REAL (never a
/// test/sim run), this streams the run's events to the proxy and polls for a
/// line the agent ("home") pushes back, playing it in whatever distinct,
/// non-coach voice the agent specifies — so a voice that isn't Ricky or Jessica
/// is audibly "home". Entirely opt-in; does nothing unless the toggle is on.
///
/// Race day (founder, 2026-10-17): in ACTUAL race mode the uplink is always on
/// and carries the full event data (GPS fixes, metrics, battery, camera), so
/// the Control Room can put him on the course map live. Batches that fail to
/// send are kept and resent in order: the first half hour of the Tianjin
/// start has no signal, and those events arrive in a burst when it returns.
///
/// Talk-back (founder, 2026-10-17): the DOWNLINK (inject poll) runs for every
/// real run in every mode, uplink or not, so an answer to something he said
/// through Siri reaches his ears. Polling only asks "is there a line for this
/// run id"; nothing about the run goes up unless sharing or racing.
@MainActor
final class LiveShareController {
    static let shared = LiveShareController()

    static let flagKey = "aarc.liveShare"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: flagKey) }

    private var runId: String?
    /// True when events go up (sharing on, or actual race). False = downlink only.
    private(set) var uplink = false
    /// True for an actual-race uplink: every event carries its data map.
    private(set) var raceUplink = false
    private var buffer: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var sending = false
    /// Backlog cap during an outage: ~2 h of fixes every 20 m plus the rest.
    private static let maxBacklog = 6000
    private static let chunk = 200
    private(set) var droppedEvents = 0
    private(set) var lastSendOK: Date?

    private static func token() -> String? {
        (Bundle.main.object(forInfoDictionaryKey: "AARCLiveDeviceToken") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Begin the channel for a REAL run. No-op for test/sim runs. The uplink
    /// (events going home) needs sharing on or actual race mode; the downlink
    /// (lines coming back) is always on.
    func startIfEnabled(runId: UUID, isTest: Bool, startedAt: Date) {
        let race = RunOrchestrator.shared.raceMode == .actual
        guard !isTest, Self.token() != nil else { return }
        self.runId = runId.uuidString
        uplink = Self.enabled || race
        raceUplink = race
        buffer = []
        droppedEvents = 0
        flushTask?.cancel(); pollTask?.cancel(); flushTask = nil
        if uplink {
            let iso = ISO8601DateFormatter().string(from: startedAt)
            var start: [String: Any] = ["runId": runId.uuidString, "isTest": false, "startedAt": iso]
            if race { start["race"] = true; start["course"] = RacePackStore.courseId }
            Task { _ = await self.send("live/start", start) }
            flushTask = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(12)); await self?.flush() }
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // 2 s for three minutes after he speaks to Control Room, so the
                // answer is not waiting on a 10 s poll; 10 s otherwise.
                let hot = Date() < ControlRoomChannel.shared.hotUntil
                try? await Task.sleep(for: .seconds(hot ? 2 : 10))
                await self?.pollInject()
                await ControlRoomChannel.shared.retryPending()
            }
        }
        NSLog("[live] channel up for real run \(runId.uuidString.prefix(8)) uplink=\(uplink) race=\(race)")
    }

    /// Mirror a run event into the live feed (called from RunEventLog.record).
    func append(type: String, detail: String, t: Double, data: [String: String] = [:]) {
        guard runId != nil, uplink else { return }
        var ev: [String: Any] = ["t": Int(t), "type": type, "detail": String(detail.prefix(220))]
        if raceUplink, !data.isEmpty { ev["data"] = data }
        buffer.append(ev)
        if buffer.count > Self.maxBacklog {
            // Shed the oldest fixes first; spoken lines and state changes stay.
            if let i = buffer.firstIndex(where: { ($0["type"] as? String) == "gps" || ($0["type"] as? String) == "metrics" }) {
                buffer.remove(at: i)
            } else {
                buffer.removeFirst()
            }
            droppedEvents += 1
        }
        if buffer.count >= 40, lastSendOK != nil { Task { await self.flush() } }
    }

    func end() {
        guard let rid = runId else { return }
        flushTask?.cancel(); pollTask?.cancel(); flushTask = nil; pollTask = nil
        let pending = buffer; buffer = []; runId = nil; raceUplink = false
        let hadUplink = uplink; uplink = false
        guard hadUplink else { NSLog("[live] channel down"); return }
        Task {
            // Best effort: a couple of tries for the tail, then the end mark.
            var rest = pending
            for _ in 0..<3 where !rest.isEmpty {
                let head = Array(rest.prefix(Self.chunk))
                if await self.send("live/events", ["runId": rid, "events": head]) { rest.removeFirst(head.count) }
                else { break }
            }
            _ = await self.send("live/end", ["runId": rid])
            NSLog("[live] sharing ended")
        }
    }

    /// Send the backlog in order, oldest first, in chunks. A failed chunk is
    /// kept at the front and retried on the next flush; nothing is dropped.
    private func flush() async {
        guard let rid = runId, !buffer.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        while !buffer.isEmpty, runId == rid {
            let head = Array(buffer.prefix(Self.chunk))
            let ok = await send("live/events", ["runId": rid, "events": head])
            guard ok else { return }
            buffer.removeFirst(min(head.count, buffer.count))
        }
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
        // .milestone priority — founder directive (2026-07-21, after his 5K
        // report got preempted by the 7K split, "oops"-resumed, and cut again
        // → never heard): "home base should have higher priority as your line
        // is going to be the most relevant and things I do need to know."
        // At .milestone: a home line still doesn't CUT a playing coach line
        // (equal priority never preempts — the earlier 'you cut over Rick'
        // fix holds), but once playing it can't be guillotined by a km split
        // either; the split queues right behind it. Generous expiry so a busy
        // stretch delays rather than drops it.
        Speaker.shared.speak(text, priority: .milestone, source: "home",
                             expiresAfter: 240, voiceId: voiceId)
        ControlRoomChannel.shared.lastAnswerAt = Date()
    }

    @discardableResult
    private func send(_ path: String, _ body: [String: Any]) async -> Bool {
        guard let token = Self.token() else { return false }
        var req = URLRequest(url: Config.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return false }
        lastSendOK = Date()
        return true
    }
}
