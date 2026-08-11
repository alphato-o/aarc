import Foundation

/// Remembers that a run was IN PROGRESS, so a crash can't erase it.
///
/// Built after the Qingdao run (55D745CB, 2026-08-09): the phone crashed while
/// generating the closing speech, and on relaunch the app had no idea a 7km+
/// run had ever happened. The workout was safe in HealthKit the whole time —
/// the watch never faltered — but nothing on the phone knew to go looking for
/// it, so the run simply vanished from the founder's history.
///
/// Everything the app knew about an active run lived in memory
/// (`LiveMetricsConsumer.currentRunId`, `RunOrchestrator` state). The per-run
/// event log was already written to disk as it went, but nothing recorded the
/// simple fact "a run is open and has not been finished". That one missing
/// breadcrumb is the whole bug, and this is the breadcrumb.
///
/// Deliberately UserDefaults and deliberately tiny: it must survive a hard
/// crash, cost nothing to write on the run's hot path, and never itself be a
/// reason a run fails to start.
@MainActor
enum UnfinishedRunStore {
    private static let key = "aarc.run.unfinished"

    struct Marker: Codable, Equatable {
        let runId: UUID
        let startedAt: Date
        let runTypeRaw: String
        let personalityId: String
        let isTest: Bool
        /// Bumped as metrics arrive, so recovery can tell a run that died at
        /// 40 minutes from one that died 5 seconds in.
        var lastSeenAt: Date
    }

    /// The open run, if the app died before finishing one.
    static var pending: Marker? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Called when a run starts. Overwrites any stale marker — a new run
    /// supersedes an older orphan, and the older one is beyond rescue anyway.
    static func mark(runId: UUID, startedAt: Date, runTypeRaw: String,
                     personalityId: String, isTest: Bool) {
        let m = Marker(runId: runId, startedAt: startedAt, runTypeRaw: runTypeRaw,
                       personalityId: personalityId, isTest: isTest, lastSeenAt: .now)
        write(m)
    }

    /// Cheap liveness bump. Called from the metrics path, so it must stay
    /// trivial; skips the write unless the last one is a while ago.
    static func touch() {
        guard var m = pending, Date.now.timeIntervalSince(m.lastSeenAt) > 20 else { return }
        m.lastSeenAt = .now
        write(m)
    }

    /// A run finished properly — there is nothing to recover.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func write(_ m: Marker) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
