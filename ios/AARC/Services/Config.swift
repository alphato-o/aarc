import Foundation

@MainActor
enum Config {
    /// Base URL for the AARC API proxy — now DYNAMIC: resolved per call
    /// by EndpointManager, which probes both the Cloudflare Worker and
    /// the US gateway and fails over automatically when the China→CF
    /// path degrades (the 2026-06-11 treadmill failure). The
    /// `AARC_API_BASE_URL` env override still wins for local dev.
    static var apiBaseURL: URL { EndpointManager.shared.current }
}
