import Foundation

@MainActor
enum Config {
    /// Base URL for the AARC API proxy — now DYNAMIC: resolved per call
    /// by EndpointManager, which probes both the Cloudflare Worker and
    /// the US gateway and fails over automatically when the China→CF
    /// path degrades (the 2026-06-11 treadmill failure). The
    /// `AARC_API_BASE_URL` env override still wins for local dev.
    static var apiBaseURL: URL { EndpointManager.shared.current }

    /// ALWAYS the Cloudflare Worker, never the US gateway. D1 + R2 live only
    /// on Cloudflare, so run ingest, the dashboard sync, the recycle-bin
    /// endpoints and personal-notes MUST target it — the gateway 503s those
    /// routes. (The 2026-06-13 "run never reached the dashboard" bug: a
    /// congested night failed the app over to the gateway, and the run-end
    /// ingest then 503'd forever.)
    static var cloudBaseURL: URL { EndpointManager.shared.cloudflareURL }
}
