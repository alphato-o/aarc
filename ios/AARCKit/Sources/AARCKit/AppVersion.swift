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

    /// Build datetime (YYYYMMDDHHMM), stamped at compile time into the
    /// custom AARCBuildStamp key. Lives outside CFBundleShortVersionString
    /// so the marketing version stays App Store Connect-legal (X.Y.Z)
    /// while the founder can still see exactly when a build was cut.
    public static var buildStamp: String {
        Bundle.main.infoDictionary?["AARCBuildStamp"] as? String ?? "?"
    }

    /// Compact "v0.2.0 (78 · 202606110130)" form for diagnostic UI —
    /// semantic version, bumped build number, and the cut datetime.
    public static var versionString: String {
        "v\(marketing) (\(build) · \(buildStamp))"
    }
}
