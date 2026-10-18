import Foundation
import Observation
import OSLog
import Network

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
        /// Hysteresis (18 Oct: four CF/US flips in the first 11 s of a run).
        var failingSince: Date?
        var consecutiveOK = 0
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
            if pathUp { setDark(false, why: "\(endpointId) delivered") }
        } else {
            kick()
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

    // MARK: - Flying dark

    /// No endpoint answers: no network, or a network that black-holes ours
    /// (race day, founder 2026-10-18: "assume the first 30 mins will be
    /// offline"). While dark the run speaks only from what is on the phone,
    /// nothing waits on a request, and the probes keep trying every 10 s.
    private(set) var isDark = false
    private(set) var darkSince: Date?
    private var pathUp = true
    private let pathMonitor = NWPathMonitor()
    private var wake: CheckedContinuation<Void, Never>?
    private var lastKick = Date.distantPast
    /// Called on the main actor when the network comes back, so queued work
    /// (talk-backs, the live feed, the roast pool) goes out at once.
    private var onlineHandlers: [@MainActor () -> Void] = []

    func whenOnline(_ handler: @escaping @MainActor () -> Void) { onlineHandlers.append(handler) }

    /// A real request just failed: probe now rather than at the next tick.
    func kick() {
        guard Date().timeIntervalSince(lastKick) > 5 else { return }
        lastKick = Date()
        wake?.resume(); wake = nil
    }

    func setDark(_ dark: Bool, why: String) {
        guard dark != isDark else { return }
        isDark = dark
        if dark {
            darkSince = Date()
            RunEventLog.shared.record("net.dark", why)
        } else {
            let secs = darkSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            darkSince = nil
            RunEventLog.shared.record("net.online", "after \(secs) s dark; \(why)")
            onlineHandlers.forEach { $0() }
        }
    }

    /// Start the background probe loop. Idempotent; call at app launch.
    func startProbing() {
        guard probeTask == nil else { return }
        // Sendable and nonisolated: it runs on the monitor's queue, not main.
        let onPath: @Sendable (NWPath) -> Void = { path in
            let up = path.status == .satisfied
            Task { @MainActor in
                let m = EndpointManager.shared
                m.pathUp = up
                if !up { m.setDark(true, why: "no network path") } else { m.kick() }
            }
        }
        pathMonitor.pathUpdateHandler = onPath
        pathMonitor.start(queue: DispatchQueue(label: "aarc.netpath"))
        probeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeAll()
                self.applySelection()
                let anyUp = self.endpoints.contains { $0.consecutiveFailures == 0 && $0.lastLatencyMs != nil }
                if anyUp && self.pathUp { self.setDark(false, why: "probe answered") }
                else if !anyUp { self.setDark(true, why: self.pathUp ? "no endpoint answers" : "no network path") }
                let degraded = self.endpoints.contains { $0.consecutiveFailures > 0 }
                let pause: Double = self.isDark ? 10 : (degraded ? 15 : 60)
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.wake = c
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(pause))
                        self?.wake?.resume(); self?.wake = nil
                    }
                }
            }
        }
    }

    /// Both endpoints at once, 6 s each: a dark start is known within seconds.
    private func probeAll() async {
        let targets = endpoints.map { ($0.id, $0.url.appendingPathComponent("ping")) }
        let results = await withTaskGroup(of: (String, Int?).self) { group in
            for (id, url) in targets {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 6
                    let started = Date()
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
                    else { return (id, nil) }
                    return (id, Int(Date().timeIntervalSince(started) * 1000))
                }
            }
            var out: [(String, Int?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (id, ms) in results {
            guard let idx = endpoints.firstIndex(where: { $0.id == id }) else { continue }
            if let ms {
                endpoints[idx].lastLatencyMs = ms
                endpoints[idx].consecutiveFailures = 0
                endpoints[idx].failingSince = nil
                endpoints[idx].consecutiveOK += 1
            } else {
                endpoints[idx].consecutiveFailures += 1
                endpoints[idx].consecutiveOK = 0
                if endpoints[idx].failingSince == nil { endpoints[idx].failingSince = Date() }
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
            // Leave the Worker only after it has been failing for 20 s, and
            // come back only after two clean probes in a row: a blip no
            // longer flips every request between the two.
            let failingLong = cf.failingSince.map { Date().timeIntervalSince($0) >= 20 } ?? false
            let cfBad = (cf.consecutiveFailures >= 2 && failingLong) || cf.realFailures >= 2
            let usOk = us.healthy && us.realFailures < 2
            if cfBad, usOk {
                currentId = "us"
            } else if cf.consecutiveFailures == 0, cf.realFailures == 0, cf.consecutiveOK >= 2 || currentId == "cf" {
                currentId = "cf"
            }
        }
        if currentId != previous {
            log.error("[endpoint] switched \(previous, privacy: .public) → \(self.currentId, privacy: .public)")
            RunEventLog.shared.record("endpoint.switch", "\(previous) → \(currentId)")
        }
    }
}
