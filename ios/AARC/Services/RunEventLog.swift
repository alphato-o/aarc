import Foundation
import Observation
import os

/// One structured event in a run's timeline.
///
/// Encoded as a single JSONL line: `t` is seconds since run start (or -1
/// when recorded outside a run, e.g. pre-run Control Room chatter), `wall`
/// is the ISO-8601 wall clock, `data` is a flat string map for anything
/// endpoint-specific (latency ms, cache keys, trigger names, ...).
struct RunLogEvent: Codable, Sendable, Identifiable {
    var id = UUID()
    let t: Double
    let wall: String
    let type: String
    let detail: String
    let data: [String: String]

    /// `id` is UI-only (ForEach identity in the Control Room tail) and is
    /// deliberately NOT serialized.
    enum CodingKeys: String, CodingKey {
        case t, wall, type, detail, data
    }
}

/// Per-run structured event log: the observability backbone for post-run
/// replay (web + in-app).
///
/// - Ring buffer `recent` (last 500 events) drives the live Control Room tail.
/// - Every event is also appended as JSONL to `Documents/runlogs/RUNID.jsonl`.
/// - `recordSpeech` events carry the AudioCache key so replay can re-play the
///   exact audio the runner heard; on `endRun()` those MP3s are *pinned* into
///   `Documents/runaudio/RUNID/` so cache eviction can't lose run audio.
/// - On `endRun()` the JSONL is uploaded to the Worker (`/ingest-run`),
///   fire-and-forget with retries; unsynced runs are tracked in UserDefaults
///   and retried via `uploadPendingRuns()` at app start.
@MainActor
@Observable
final class RunEventLog {
    static let shared = RunEventLog()

    typealias Event = RunLogEvent

    // MARK: - Observable state (Control Room)

    /// Tail of the event stream — last `maxRecent` events, oldest first.
    private(set) var recent: [RunLogEvent] = []
    /// Non-nil while a run is being logged.
    private(set) var activeRunId: UUID?
    /// Events written to the active run's JSONL so far.
    private(set) var eventCount: Int = 0

    // MARK: - Internal

    private var runStartedAt: Date?
    private var fileHandle: FileHandle?
    /// AudioCache keys spoken during this run, in first-spoken order.
    private var audioManifest: [String] = []

    /// Throttle state for `recordMetrics`: the last 100m bucket index and
    /// the last wall time we emitted a "metrics" event. We emit when the
    /// runner crosses a new 100m bucket OR ~10s have elapsed since the
    /// last emit — whichever comes first — so the dashboard time-series
    /// stays dense without spamming a row on every 1Hz tick.
    private var lastMetricsBucket: Int = -1
    private var lastMetricsEmit: Date?
    private static let metricsMinInterval: TimeInterval = 10

    private let log = Logger(subsystem: "club.aarun.AARC", category: "RunEventLog")
    nonisolated private static let uploadLog = Logger(subsystem: "club.aarun.AARC", category: "RunEventLog.upload")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let wallFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let maxRecent = 500
    nonisolated private static let retentionDays = 35.0
    nonisolated private static let pendingRunsKey = "aarc.sync.pendingRuns"
    nonisolated private static let audioEnabledKey = "aarc.sync.audioEnabled"
    /// Initial attempt + 3 retries, spaced 30s. Not private: they back the
    /// default arguments of `uploadEventStream`, which `RunHistoryBackfill`
    /// calls — default-argument expressions resolve in the caller's scope.
    nonisolated static let uploadAttempts = 4
    nonisolated static let uploadRetrySpacing: Duration = .seconds(30)

    private init() {}

    // MARK: - Run lifecycle

    /// Begin logging a run. Creates `Documents/runlogs/RUNID.jsonl`, resets
    /// the tail + manifest, and prunes artifacts older than 35 days.
    func startRun(runId: UUID) {
        if activeRunId != nil {
            log.warning("startRun while a run is active — closing the dangling run first")
            endRun()
        }
        activeRunId = runId
        runStartedAt = Date()
        recent.removeAll()
        eventCount = 0
        audioManifest.removeAll()
        lastMetricsBucket = -1
        lastMetricsEmit = nil

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.runlogsDirectory, withIntermediateDirectories: true)
        let url = Self.logFileURL(for: runId)
        fm.createFile(atPath: url.path, contents: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: url)
        } catch {
            fileHandle = nil
            log.error("RunEventLog could not open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        record("run", "started", data: ["runId": runId.uuidString])
        log.info("RunEventLog started run \(runId.uuidString, privacy: .public)")

        Task.detached(priority: .utility) {
            RunEventLog.pruneOldArtifacts()
        }
    }

    /// Append one event. Always lands in the observable tail; persisted to
    /// the JSONL only while a run is active (t = -1 marks out-of-run events).
    func record(_ type: String, _ detail: String, data: [String: String] = [:]) {
        let now = Date()
        let t = runStartedAt.map { now.timeIntervalSince($0) } ?? -1
        let event = RunLogEvent(
            t: (t * 1000).rounded() / 1000,
            wall: wallFormatter.string(from: now),
            type: type,
            detail: detail,
            data: data
        )

        recent.append(event)
        if recent.count > Self.maxRecent {
            recent.removeFirst(recent.count - Self.maxRecent)
        }

        guard activeRunId != nil, let handle = fileHandle else { return }
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A) // "\n"
        do {
            try handle.write(contentsOf: line)
            eventCount += 1
        } catch {
            log.error("RunEventLog write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Record a spoken line. Carries the AudioCache key so post-run replay
    /// can play back the exact audio; the key is added to the per-run audio
    /// manifest and the MP3 is pinned out of the evictable cache at endRun().
    func recordSpeech(text: String, voiceId: String, source: String, cacheKey: String) {
        if !audioManifest.contains(cacheKey) {
            audioManifest.append(cacheKey)
        }
        record("speech", text, data: [
            "voiceId": voiceId,
            "source": source,
            "cacheKey": cacheKey,
        ])
    }

    /// Record a performance-telemetry sample as a "metrics" event.
    /// Throttled: emits only when the runner crosses a new 100m bucket OR
    /// at least ~10s have passed since the last metrics emit — so the
    /// dashboard time-series stays dense without one row per 1Hz tick.
    /// No-op outside an active run. Values map to the shared contract
    /// data shape {"d","p","hr","v"} as strings; nil → "".
    func recordMetrics(distanceMeters: Double, paceSecPerKm: Double?, hr: Double?, speedMps: Double?) {
        guard activeRunId != nil else { return }
        let bucket = Int(distanceMeters / 100)
        let now = Date()
        let crossedBucket = bucket > lastMetricsBucket
        let elapsedEnough = lastMetricsEmit.map { now.timeIntervalSince($0) >= Self.metricsMinInterval } ?? true
        guard crossedBucket || elapsedEnough else { return }
        lastMetricsBucket = max(lastMetricsBucket, bucket)
        lastMetricsEmit = now

        func num(_ v: Double?) -> String {
            guard let v, v.isFinite, v > 0 else { return "" }
            return String(format: "%.1f", v)
        }
        record("metrics", "", data: [
            "d": num(distanceMeters),
            "p": num(paceSecPerKm),
            "hr": num(hr),
            "v": num(speedMps),
        ])
    }

    /// Close the run: final event, pin run audio out of AudioCache, then
    /// fire-and-forget upload (JSONL always; MP3s only when the
    /// `aarc.sync.audioEnabled` default is on — R2 isn't enabled yet).
    func endRun() {
        guard let runId = activeRunId else { return }
        record("run", "ended", data: ["events": String(eventCount)])

        try? fileHandle?.close()
        fileHandle = nil
        let manifest = audioManifest
        activeRunId = nil
        runStartedAt = nil
        audioManifest.removeAll()
        log.info("RunEventLog ended run \(runId.uuidString, privacy: .public) events=\(self.eventCount)")

        let uploadEnabled = !(Self.deviceToken?.isEmpty ?? true)
        if uploadEnabled {
            Self.addPending(runId)
        } else {
            log.notice("RunEventLog upload skipped — AARCDeviceToken not set in Info.plist")
        }

        // Fire-and-forget: pin audio first (so even a failed upload keeps the
        // run's audio safe locally), then push the JSONL with retries, then
        // the MP3s if audio sync is enabled.
        Task.detached(priority: .utility) {
            await RunEventLog.pinRunAudio(runId: runId, keys: manifest)
            guard uploadEnabled else { return }
            await RunEventLog.uploadRun(
                runId: runId,
                attempts: RunEventLog.uploadAttempts,
                spacing: RunEventLog.uploadRetrySpacing
            )
            await RunEventLog.uploadRunAudio(runId: runId)
        }
    }

    /// Retry any runs whose upload never succeeded (tracked in UserDefaults).
    /// The orchestrator calls this once at app start. One attempt per run —
    /// stragglers stay pending for the next launch.
    func uploadPendingRuns() {
        guard let token = Self.deviceToken, !token.isEmpty else { return }
        let pending = Self.pendingRunIds()
        guard !pending.isEmpty else { return }
        let active = activeRunId
        log.info("RunEventLog retrying \(pending.count) pending upload(s)")
        Task.detached(priority: .utility) {
            for runId in pending where runId != active {
                await RunEventLog.uploadRun(runId: runId, attempts: 1, spacing: .seconds(0))
                await RunEventLog.uploadRunAudio(runId: runId)
            }
        }
    }

    // MARK: - Paths

    nonisolated private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    nonisolated static var runlogsDirectory: URL {
        documentsDirectory.appendingPathComponent("runlogs", isDirectory: true)
    }
    nonisolated static var runaudioDirectory: URL {
        documentsDirectory.appendingPathComponent("runaudio", isDirectory: true)
    }
    nonisolated static func logFileURL(for runId: UUID) -> URL {
        runlogsDirectory.appendingPathComponent("\(runId.uuidString).jsonl")
    }

    // MARK: - Archive readers (historical Control Room replay)

    /// A past run that has an on-device diagnostics log, for the history list.
    struct ArchivedRun: Identifiable, Sendable {
        let runId: UUID
        let startedAt: Date          // wall time of the first event
        let endedAt: Date?           // wall time of run.end, if present
        let eventCount: Int
        var id: UUID { runId }
        var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    }

    /// List every run with an on-device JSONL log, newest first. Cheap: reads
    /// only the first + last line of each file for the time span + a quick
    /// line count. Off-main safe.
    nonisolated static func archivedRuns() -> [ArchivedRun] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: runlogsDirectory, includingPropertiesForKeys: nil) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [ArchivedRun] = []
        for url in files where url.pathExtension == "jsonl" {
            guard let runId = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            guard !lines.isEmpty else { continue }
            func wall(_ line: Substring) -> Date? {
                guard let d = line.data(using: .utf8),
                      let ev = try? JSONDecoder().decode(RunLogEvent.self, from: d) else { return nil }
                return iso.date(from: ev.wall)
            }
            let start = wall(lines.first!) ?? Date(timeIntervalSince1970: 0)
            // run.end is normally the last meaningful line.
            let end = lines.reversed().lazy.compactMap { line -> Date? in
                guard let d = line.data(using: .utf8),
                      let ev = try? JSONDecoder().decode(RunLogEvent.self, from: d),
                      ev.type == "run.end" || ev.type == "run" else { return nil }
                return iso.date(from: ev.wall)
            }.first ?? wall(lines.last!)
            out.append(ArchivedRun(runId: runId, startedAt: start, endedAt: end, eventCount: lines.count))
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// Load the full ordered event stream for a past run (for the replayed
    /// Control Room). Off-main safe.
    nonisolated static func loadEvents(runId: UUID) -> [RunLogEvent] {
        let url = logFileURL(for: runId)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(RunLogEvent.self, from: d)
        }
    }
    nonisolated static func audioDirectory(for runId: UUID) -> URL {
        runaudioDirectory.appendingPathComponent(runId.uuidString, isDirectory: true)
    }

    // MARK: - Audio pinning

    /// Copy each manifest key's cached MP3 from the evictable AudioCache into
    /// `Documents/runaudio/RUNID/KEY.mp3`. Keys already evicted are skipped
    /// (the speech event still documents what was said).
    nonisolated private static func pinRunAudio(runId: UUID, keys: [String]) async {
        guard !keys.isEmpty else { return }
        let fm = FileManager.default
        let dir = audioDirectory(for: runId)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var pinned = 0
        for key in keys {
            let dest = dir.appendingPathComponent("\(key).mp3")
            guard !fm.fileExists(atPath: dest.path) else { continue }
            guard let src = await AudioCache.shared.url(forKey: key) else { continue }
            do {
                try fm.copyItem(at: src, to: dest)
                pinned += 1
            } catch {
                uploadLog.error("pin failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        uploadLog.info("pinned \(pinned)/\(keys.count) audio file(s) for run \(runId.uuidString, privacy: .public)")
    }

    // MARK: - Upload

    nonisolated private static var deviceToken: String? {
        Bundle.main.object(forInfoDictionaryKey: "AARCDeviceToken") as? String
    }

    /// True when a device token is configured, i.e. uploads can succeed.
    /// Lets `RunHistoryBackfill` bail out early without poking at the
    /// private token directly.
    nonisolated static var backfillUploadEnabled: Bool {
        !(deviceToken?.isEmpty ?? true)
    }

    /// POST the run's JSONL to the Worker. Plain body (runs are tens of KB;
    /// the Worker also accepts Content-Encoding: gzip if we compress later).
    /// On success the run leaves the pending list; on exhaustion it stays
    /// for `uploadPendingRuns()`.
    nonisolated private static func uploadRun(runId: UUID, attempts: Int, spacing: Duration) async {
        guard let token = deviceToken, !token.isEmpty else { return }
        let fileURL = logFileURL(for: runId)
        guard let body = try? Data(contentsOf: fileURL), !body.isEmpty else {
            // Log file is gone (pruned or never written) — nothing to sync.
            removePending(runId)
            return
        }
        let ok = await postRunBody(runId: runId, body: body, token: token, attempts: attempts, spacing: spacing)
        if ok {
            removePending(runId)
            await MainActor.run { RunEventLog.syncedRunId = runId }
        }
    }

    /// The most recently cloud-synced run id — the post-run summary waits on
    /// this (alongside the closing roast) before it stops "preparing".
    @MainActor static var syncedRunId: UUID?

    /// Upload an arbitrary JSONL event stream as a run to `/ingest-run`.
    /// Reusable entry point (used by `RunHistoryBackfill` to push
    /// synthesised historical runs without first writing a local JSONL
    /// file). Returns true on a 2xx, false on exhaustion / hard failure.
    /// Does NOT touch the pending-runs list — backfill tracks its own
    /// done-set in UserDefaults.
    nonisolated static func uploadEventStream(
        runId: UUID,
        jsonlLines: [String],
        attempts: Int = uploadAttempts,
        spacing: Duration = uploadRetrySpacing
    ) async -> Bool {
        guard let token = deviceToken, !token.isEmpty else { return false }
        guard !jsonlLines.isEmpty else { return false }
        let joined = jsonlLines.joined(separator: "\n") + "\n"
        guard let body = joined.data(using: .utf8), !body.isEmpty else { return false }
        return await postRunBody(runId: runId, body: body, token: token, attempts: attempts, spacing: spacing)
    }

    /// Shared POST-with-retries core behind `uploadRun` and
    /// `uploadEventStream`. Returns true on a 2xx (caller decides what
    /// bookkeeping that implies). 401 short-circuits (a token mismatch
    /// won't fix itself by retrying).
    nonisolated private static func postRunBody(
        runId: UUID,
        body: Data,
        token: String,
        attempts: Int,
        spacing: Duration
    ) async -> Bool {
        let base = await MainActor.run { Config.cloudBaseURL }
        var request = URLRequest(url: base.appendingPathComponent("ingest-run"))
        request.httpMethod = "POST"
        request.setValue(runId.uuidString, forHTTPHeaderField: "X-Run-Id")
        request.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        for attempt in 1...max(1, attempts) {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<300).contains(status) {
                    uploadLog.info("run \(runId.uuidString, privacy: .public) uploaded (\(body.count) bytes, attempt \(attempt))")
                    return true
                }
                if status == 401 {
                    // Token mismatch won't fix itself by retrying.
                    uploadLog.error("ingest-run 401 — device token rejected; keeping run pending")
                    return false
                }
                uploadLog.error("ingest-run HTTP \(status) (attempt \(attempt)/\(attempts))")
            } catch {
                uploadLog.error("ingest-run failed (attempt \(attempt)/\(attempts)): \(error.localizedDescription, privacy: .public)")
            }
            if attempt < attempts {
                try? await Task.sleep(for: spacing)
            }
        }
        return false
    }

    /// POST each pinned MP3 to /ingest-audio. Gated on the
    /// `aarc.sync.audioEnabled` default (R2 not yet enabled on the CF
    /// account; defaults to false). Best-effort — re-runs via
    /// uploadPendingRuns() while the run stays pending.
    nonisolated private static func uploadRunAudio(runId: UUID) async {
        guard UserDefaults.standard.bool(forKey: audioEnabledKey) else { return }
        guard let token = deviceToken, !token.isEmpty else { return }
        let audioBase = await MainActor.run { Config.cloudBaseURL }
        let fm = FileManager.default
        let dir = audioDirectory(for: runId)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "mp3" {
            let key = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file) else { continue }
            guard var comps = URLComponents(
                url: audioBase.appendingPathComponent("ingest-audio"),
                resolvingAgainstBaseURL: false
            ) else { continue }
            comps.queryItems = [
                URLQueryItem(name: "runId", value: runId.uuidString),
                URLQueryItem(name: "key", value: key),
            ]
            guard let url = comps.url else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "X-AARC-Device")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            request.timeoutInterval = 30
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 503 {
                    uploadLog.notice("ingest-audio 503 — R2 not enabled on the Worker yet; stopping audio sync for this run")
                    return
                }
                if !(200..<300).contains(status) {
                    uploadLog.error("ingest-audio HTTP \(status) for key \(key, privacy: .public)")
                }
            } catch {
                uploadLog.error("ingest-audio failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Pending-run bookkeeping (UserDefaults)

    nonisolated private static func pendingRunIds() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: pendingRunsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
    }

    nonisolated private static func addPending(_ runId: UUID) {
        var list = UserDefaults.standard.stringArray(forKey: pendingRunsKey) ?? []
        guard !list.contains(runId.uuidString) else { return }
        list.append(runId.uuidString)
        UserDefaults.standard.set(list, forKey: pendingRunsKey)
    }

    nonisolated private static func removePending(_ runId: UUID) {
        var list = UserDefaults.standard.stringArray(forKey: pendingRunsKey) ?? []
        list.removeAll { $0 == runId.uuidString }
        UserDefaults.standard.set(list, forKey: pendingRunsKey)
    }

    // MARK: - Retention

    /// Delete runlogs/*.jsonl and runaudio/RUNID/ older than 35 days. Runs
    /// off-main at every startRun.
    nonisolated private static func pruneOldArtifacts() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-retentionDays * 86_400)
        for dir in [runlogsDirectory, runaudioDirectory] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for item in items {
                guard
                    let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                    let modified = values.contentModificationDate,
                    modified < cutoff
                else { continue }
                try? fm.removeItem(at: item)
                if let runId = UUID(uuidString: item.deletingPathExtension().lastPathComponent) {
                    removePending(runId)
                }
            }
        }
    }
}
