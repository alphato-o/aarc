import Foundation

/// Compact, cross-process record of the runner's most recent completed
/// run. Written to a shared App Group container by the main AARC app
/// when a run lands; read by the home-screen widget extension.
///
/// Kept deliberately small and Codable — the widget is bandwidth- and
/// memory-budget constrained, so we ship only the fields the widget
/// actually renders. Heavier data (full HR series, route polyline) can
/// be added later behind feature flags if needed.
public struct LastRunSnapshot: Codable, Sendable, Hashable {
    public let runId: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let distanceMeters: Double
    public let durationSeconds: Double
    public let avgPaceSecPerKm: Double
    public let energyKcal: Double
    /// "outdoor" or "treadmill".
    public let runTypeRaw: String
    /// Pace in sec/km, one entry per full km the runner completed.
    /// Drives the per-km pace line on the medium widget. Optional —
    /// older snapshots may not have it; the widget renders fine without.
    public let paceSplits: [Double]?
    /// Average heart rate, one entry per full km, ALIGNED with paceSplits.
    /// Drives the per-km HR line on the medium widget. Optional — and
    /// individual entries may be 0 when no HR samples were recorded in
    /// that km (HR strap dropout, indoor with no watch HR, etc.).
    public let hrSplits: [Double]?

    public init(
        runId: UUID,
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        durationSeconds: Double,
        avgPaceSecPerKm: Double,
        energyKcal: Double,
        runTypeRaw: String,
        paceSplits: [Double]?,
        hrSplits: [Double]? = nil
    ) {
        self.runId = runId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.avgPaceSecPerKm = avgPaceSecPerKm
        self.energyKcal = energyKcal
        self.runTypeRaw = runTypeRaw
        self.paceSplits = paceSplits
        self.hrSplits = hrSplits
    }

    /// App Group identifier used by both the AARC iOS target and the
    /// AARCLiveActivity widget extension. Must match the entitlement
    /// in both targets AND be enabled in App Store Connect / Developer
    /// Portal under Identifiers → App Groups.
    public static let appGroupId = "group.club.aarun.AARC"

    /// Filename inside the App Group container.
    public static let filename = "last_run.json"

    /// URL of the shared JSON file. Returns nil when the App Group
    /// entitlement hasn't been provisioned yet (e.g., dev build before
    /// the capability is wired in the Developer Portal).
    public static func sharedFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(filename)
    }

    public static func load() -> LastRunSnapshot? {
        guard let url = sharedFileURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastRunSnapshot.self, from: data)
    }
}
