import Foundation

/// Reads the running app's bundle for marketing version + build number.
/// Works identically from iOS and watchOS callers because each target's
/// `Bundle.main` resolves to its own .app, even when this code is shipped
/// via a shared Swift package.
public enum AppVersion {
    public static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Compact "v0.1.0 (12)" form for diagnostic UI.
    public static var versionString: String {
        "v\(marketing) (\(build))"
    }
}
