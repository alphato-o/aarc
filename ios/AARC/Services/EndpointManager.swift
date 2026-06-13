import Foundation
import Observation
import OSLog

/// Multi-endpoint transport with automatic failover. Born from the
/// 2026-06-11 treadmill run where the China-carrier → Cloudflare path
/// timed out for everything while the phone otherwise had internet.
///
/// Two endpoints:
///   - Cloudflare Worker (api.aarun.club) — full feature set incl. run
///     ingest, dashboard, voice archive (D1/R2 live there).
///   - US gateway (gateway.aarun.club:8443) — direct grey-cloud route to
///     a US VPS; LLM + TTS only (diagnostics routes 503 there, and the
///     RunEventLog pending-upload mechanism retries them on the Worker
///     later, so nothing is lost while failed over).
///
/// Selection: a probe loop pings BOTH every 60s (15s while degraded).
/// "Auto" prefers the Worker when healthy; two consecutive Worker probe
/// failures with a healthy gateway → switch; recovery switches back.
/// Manual override via UserDefaults ("aarc.endpoint.mode": auto|cf|us)
/// for the Control Room / Settings.
@Observable
@MainActor
final class EndpointManager {
    static let shared = EndpointManager()

    static let modeKey = "aarc.endpoint.mode"   // "auto" | "cf" | "us"

    struct Endpoint: Identifiable {
        let id: String          // "cf" | "us"
        let name: String
        let url: URL
        var lastLatencyMs: Int?
        var consecutiveFailures: Int = 0
        /// Strikes from REAL traffic (TTS transfers failing or losing a
        /// hedge race) — probes can stay green on a congested route while
        /// actual payloads starve, so these are tracked separately and are
        /// NOT cleared by a successful ping. Cleared by a real success, or
        /// by 10 minutes without a new strike.
        var realFailures: Int = 0
        var lastRealFailureAt: Date?
        var healthy: Bool { consecutiveFailures == 0 && lastLatencyMs != nil }
    }

    private(set) var endpoints: [Endpoint] = [
        Endpoint(id: "cf", name: "Cloudflare", url: URL(string: "https://api.aarun.club")!),
        Endpoint(id: "us", name: "US Gateway", url: URL(string: "https://gateway.aarun.club:8443")!),
    ]

    /// Which endpoint API calls should use right now.
    private(set) var currentId: String = "cf"
    var current: URL {
        // Dev override keeps working exactly as before.
        if let override = ProcessInfo.processInfo.environment["AARC_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        return endpoints.first { $0.id == currentId }?.url ?? endpoints[0].url
    }
    var currentName: String { endpoints.first { $0.id == currentId }?.name ?? "?" }

    /// The Cloudflare Worker URL, regardless of failover state — for D1/R2
    /// routes that ONLY exist on Cloudflare (ingest, dashboard sync, etc.).
    /// Honors the dev override like `current` does.
    var cloudflareURL: URL {
        if let override = ProcessInfo.processInfo.environment["AARC_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        return endpoints.first { $0.id == "cf" }?.url ?? endpoints[0].url
    }

    /// Snapshot of the active endpoint (for transports that need the id,
    /// e.g. hedged requests reporting outcomes per endpoint).
    var currentEndpoint: Endpoint { endpoints.first { $0.id == currentId } ?? endpoints[0] }
    /// The endpoint we are NOT currently using — the hedge target.
    var alternate: Endpoint? { endpoints.first { $0.id != currentId } }

    /// Real-traffic verdict from the transport layer. `ok: false` covers
    /// both hard failures AND losing a hedge race (slow is the failure
    /// mode on a congested-but-pingable route — the 2026-06-12 23:57 run
    /// crawled at 2 KB/s for 7 minutes with every probe green).
    func reportOutcome(endpointId: String, ok: Bool, reason: String = "") {
        guard let idx = endpoints.firstIndex(where: { $0.id == endpointId }) else { return }
        if ok {
            endpoints[idx].realFailures = 0
            endpoints[idx].lastRealFailureAt = nil
        } else {
            endpoints[idx].realFailures += 1
            endpoints[idx].lastRealFailureAt = Date()
            log.error("[endpoint] real-traffic strike \(self.endpoints[idx].realFailures, privacy: .public) on \(endpointId, privacy: .public): \(reason, privacy: .public)")
            applySelection()
        }
    }

    var mode: String {
        get { UserDefaults.standard.string(forKey: Self.modeKey) ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.modeKey)
            applySelection()
        }
    }

    private var probeTask: Task<Void, Never>?
    private let log = Logger(subsystem: "club.aarun.AARC", category: "Endpoint")

    /// Start the background probe loop. Idempotent; call at app launch.
    func startProbing() {
        guard probeTask == nil else { return }
        probeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeAll()
                self.applySelection()
                let degraded = self.endpoints.contains { $0.consecutiveFailures > 0 }
                try? await Task.sleep(for: .seconds(degraded ? 15 : 60))
            }
        }
    }

    private func probeAll() async {
        for idx in endpoints.indices {
            let url = endpoints[idx].url.appendingPathComponent("ping")
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let started = Date()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    endpoints[idx].lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                    endpoints[idx].consecutiveFailures = 0
                } else {
                    endpoints[idx].consecutiveFailures += 1
                }
            } catch {
                endpoints[idx].consecutiveFailures += 1
            }
        }
    }

    private func applySelection() {
        // Real-traffic strikes age out after 10 minutes without a new one,
        // so a congested evening doesn't pin us off the Worker forever —
        // and per-request hedging protects every transfer in the meantime.
        for idx in endpoints.indices {
            if let t = endpoints[idx].lastRealFailureAt, Date().timeIntervalSince(t) > 600 {
                endpoints[idx].realFailures = 0
                endpoints[idx].lastRealFailureAt = nil
            }
        }
        let previous = currentId
        switch mode {
        case "cf": currentId = "cf"
        case "us": currentId = "us"
        default:
            // Auto: Worker preferred. Fail over on 2 consecutive probe
            // failures OR 2 real-traffic strikes, if the gateway looks
            // usable; recover only when the Worker is clean on BOTH
            // signals (probe green alone must not flap us back while
            // actual transfers are still starving).
            let cf = endpoints.first { $0.id == "cf" }!
            let us = endpoints.first { $0.id == "us" }!
            let cfBad = cf.consecutiveFailures >= 2 || cf.realFailures >= 2
            let usOk = us.healthy && us.realFailures < 2
            if cfBad, usOk {
                currentId = "us"
            } else if cf.consecutiveFailures == 0, cf.realFailures == 0 {
                currentId = "cf"
            }
        }
        if currentId != previous {
            log.error("[endpoint] switched \(previous, privacy: .public) → \(self.currentId, privacy: .public)")
            RunEventLog.shared.record("endpoint.switch", "\(previous) → \(currentId)")
        }
    }
}
