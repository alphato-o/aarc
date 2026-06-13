import Foundation

/// Mirrors local run deletions to the cloud dashboard so the iPhone stays
/// the source of truth: soft-delete on the phone -> soft-delete in D1 (the
/// dashboard's recycle bin), restore -> restore, permanent -> purge.
///
/// Best-effort + fire-and-forget. The cloud run_id is the diagnostics
/// (RunEventLog) runId, which differs from the local RunRecord.id — callers
/// pass the matched ArchivedRun's runId (matched by start time in History).
enum CloudRunSync {
    private static var deviceToken: String? {
        Bundle.main.object(forInfoDictionaryKey: "AARCDeviceToken") as? String
    }

    static func delete(runId: UUID) { post(runId, "delete") }
    static func restore(runId: UUID) { post(runId, "restore") }
    static func purge(runId: UUID) { post(runId, "purge") }

    private static func post(_ runId: UUID, _ action: String) {
        guard let token = deviceToken, !token.isEmpty else { return }
        Task { @MainActor in
            let url = Config.cloudBaseURL
                .appendingPathComponent("api/runs/\(runId.uuidString)/\(action)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
            req.timeoutInterval = 15
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
