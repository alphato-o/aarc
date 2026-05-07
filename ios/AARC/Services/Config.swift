import Foundation

enum Config {
    /// Base URL for the AARC API proxy. Override with `AARC_API_BASE_URL`
    /// in scheme env vars during local proxy development (e.g. http://localhost:8787).
    static let apiBaseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["AARC_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.aarun.club")!
    }()
}
