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
        let previous = currentId
        switch mode {
        case "cf": currentId = "cf"
        case "us": currentId = "us"
        default:
            // Auto: Worker preferred; fail over after 2 consecutive probe
            // failures IF the gateway looks healthy; recover when the
            // Worker answers again.
            let cf = endpoints.first { $0.id == "cf" }!
            let us = endpoints.first { $0.id == "us" }!
            if cf.consecutiveFailures >= 2, us.healthy {
                currentId = "us"
            } else if cf.consecutiveFailures == 0 {
                currentId = "cf"
            }
        }
        if currentId != previous {
            log.error("[endpoint] switched \(previous, privacy: .public) → \(self.currentId, privacy: .public)")
            RunEventLog.shared.record("endpoint.switch", "\(previous) → \(currentId)")
        }
    }
}
