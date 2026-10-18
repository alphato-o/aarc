import Foundation

/// What music played when, for the race video (founder, 2026-10-18). Two
/// sources: an in-run poll of Spotify's currently-playing (every track
/// change and pause, timed to the second), and Spotify's recently-played
/// history after the fact, which covers stretches the phone was dark.
/// Everything is queued on disk and sent to /live/music until it lands.
@MainActor
final class MusicTimeline {
    static let shared = MusicTimeline()

    struct Play: Codable, Equatable {
        let runId: String
        let source: String      // "live" | "history"
        let at: Date            // live: track start; history: Spotify's played_at
        let event: String       // "track" | "pause" | "resume" | "played"
        let trackId: String?
        let title: String
        let artist: String
        let album: String?
        let durationMs: Int?
    }

    /// A finished run whose history still needs pulling (Spotify only syncs
    /// offline plays later, so this is retried for two days).
    private struct Backfill: Codable { let runId: String; let start: Date; let end: Date; var tries: Int }

    private var queue: [Play] = []
    private var backfills: [Backfill] = []
    private var runId: String?
    private var runStart: Date?
    private var lastTrackKey: String?
    private var lastTitle = ""
    private var lastPlaying: Bool?
    private var pollTask: Task<Void, Never>?
    private var sending = false
    private var warnedPermission = false

    private static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var queueURL: URL { dir.appendingPathComponent("music-queue.json") }
    private static var backfillURL: URL { dir.appendingPathComponent("music-backfill.json") }

    init() {
        if let d = try? Data(contentsOf: Self.queueURL), let q = try? JSONDecoder().decode([Play].self, from: d) { queue = q }
        if let d = try? Data(contentsOf: Self.backfillURL), let b = try? JSONDecoder().decode([Backfill].self, from: d) { backfills = b }
        EndpointManager.shared.whenOnline { Task { await MusicTimeline.shared.catchUp() } }
    }

    // MARK: - Run lifecycle

    func start(runId: UUID, startedAt: Date) {
        guard SpotifyAuth.shared.isConnected else {
            RunEventLog.shared.record("music.timeline", "Spotify not connected: no soundtrack log for this run")
            return
        }
        self.runId = runId.uuidString
        runStart = startedAt
        lastTrackKey = nil
        lastPlaying = nil
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !EndpointManager.shared.isDark {
                    await self.poll()
                    // Spotify keeps only ~50 plays: pull history every 20 min
                    // while online so a 4-hour race is never beyond its reach.
                    if tick > 0, tick % 150 == 0, let rid = self.runId, let s = self.runStart {
                        await self.pullHistory(runId: rid, start: s, end: .now)
                    }
                    await self.flush()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func end() {
        pollTask?.cancel(); pollTask = nil
        guard let rid = runId, let s = runStart else { return }
        runId = nil; runStart = nil
        backfills.append(Backfill(runId: rid, start: s, end: .now, tries: 0))
        saveBackfills()
        Task { await self.catchUp() }
    }

    /// App launch and network return: send what is queued, retry backfills.
    func catchUp() async {
        guard !EndpointManager.shared.isDark else { return }
        for i in backfills.indices.reversed() {
            let b = backfills[i]
            let ok = await pullHistory(runId: b.runId, start: b.start, end: b.end)
            backfills[i].tries += 1
            // Twice more after a success (offline plays sync late), then done; give up after two days.
            if (ok && backfills[i].tries >= 3) || Date().timeIntervalSince(b.end) > 48 * 3600 { backfills.remove(at: i) }
        }
        saveBackfills()
        await flush()
    }

    // MARK: - Sources

    private func poll() async {
        guard let rid = runId else { return }
        switch await SpotifyClient.shared.currentlyPlaying() {
        case .track(let t):
            let key = t.id ?? "\(t.title)|\(t.artist)"
            if key != lastTrackKey {
                lastTrackKey = key
                lastTitle = t.title
                lastPlaying = t.isPlaying
                let started = Date().addingTimeInterval(-Double(t.progressMs ?? 0) / 1000)
                append(Play(runId: rid, source: "live", at: started, event: "track", trackId: t.id,
                            title: t.title, artist: t.artist, album: t.album, durationMs: t.durationMs))
                RunEventLog.shared.record("music.track", "\(t.title) · \(t.artist)",
                                          data: ["trackId": t.id ?? "", "startedAgoMs": String(t.progressMs ?? 0)])
            } else if t.isPlaying != lastPlaying {
                lastPlaying = t.isPlaying
                append(Play(runId: rid, source: "live", at: .now, event: t.isPlaying ? "resume" : "pause", trackId: t.id,
                            title: t.title, artist: t.artist, album: t.album, durationMs: t.durationMs))
                RunEventLog.shared.record("music.track", t.isPlaying ? "resumed" : "paused")
            }
        case .nothingPlaying:
            if lastPlaying == true, lastTrackKey != nil {
                lastPlaying = false
                append(Play(runId: rid, source: "live", at: .now, event: "pause", trackId: nil,
                            title: lastTitle, artist: "", album: nil, durationMs: nil))
                RunEventLog.shared.record("music.track", "nothing playing")
            }
        case .notConnected:
            break
        }
    }

    /// True when Spotify answered (even with nothing new).
    @discardableResult
    private func pullHistory(runId: String, start: Date, end: Date) async -> Bool {
        switch await SpotifyClient.shared.recentlyPlayed(after: start.addingTimeInterval(-60)) {
        case .plays(let plays):
            let mine = plays.filter { $0.playedAt >= start && $0.playedAt <= end.addingTimeInterval(15 * 60) }
            for p in mine {
                append(Play(runId: runId, source: "history", at: p.playedAt, event: "played", trackId: p.id,
                            title: p.title, artist: p.artist, album: p.album, durationMs: p.durationMs))
            }
            return true
        case .noPermission:
            if !warnedPermission {
                warnedPermission = true
                RunEventLog.shared.record("music.timeline", "Spotify history needs a reconnect (Settings, Spotify): offline stretches will have no track names")
            }
            return false
        case .unavailable:
            return false
        }
    }

    // MARK: - Queue

    private func append(_ p: Play) {
        guard !queue.contains(p) else { return }
        queue.append(p)
        saveQueue()
    }

    private func flush() async {
        guard !sending, !queue.isEmpty, let token = Bundle.main.object(forInfoDictionaryKey: "AARCLiveDeviceToken") as? String,
              !token.isEmpty else { return }
        sending = true
        defer { sending = false }
        let iso = ISO8601DateFormatter()
        for runId in Set(queue.map(\.runId)) {
            let batch = queue.filter { $0.runId == runId }.prefix(200)
            let body: [String: Any] = ["runId": runId, "plays": batch.map { p -> [String: Any] in
                var d: [String: Any] = ["source": p.source, "at": iso.string(from: p.at), "event": p.event,
                                        "title": p.title, "artist": p.artist]
                if let v = p.trackId { d["trackId"] = v }
                if let v = p.album { d["album"] = v }
                if let v = p.durationMs { d["durationMs"] = v }
                return d
            }]
            var req = URLRequest(url: Config.cloudBaseURL.appendingPathComponent("live/music"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
            req.timeoutInterval = 15
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return }
            let sent = Array(batch)
            queue.removeAll { sent.contains($0) }
            saveQueue()
        }
    }

    private func saveQueue() {
        if let d = try? JSONEncoder().encode(queue) { try? d.write(to: Self.queueURL, options: .atomic) }
    }
    private func saveBackfills() {
        if let d = try? JSONEncoder().encode(backfills) { try? d.write(to: Self.backfillURL, options: .atomic) }
    }
}
