import Foundation

/// What the user is committing to before they hit Start. Drives both
/// the script generator (which adapts the message structure to the
/// plan kind) and the ScriptEngine (which evaluates halfway / finish
/// against the appropriate axis — meters for distance plans, seconds
/// for time plans, never for open plans).
public struct RunPlan: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// "Run X km" — the existing default.
        case distance
        /// "Run for Y minutes" — timeboxed.
        case time
        /// "Just run, until I stop." — no halfway, no finish.
        case open
    }

    public let kind: Kind
    /// Set when `kind == .distance`.
    public let distanceKm: Double?
    /// Set when `kind == .time`.
    public let timeMinutes: Double?

    public init(kind: Kind, distanceKm: Double? = nil, timeMinutes: Double? = nil) {
        self.kind = kind
        self.distanceKm = distanceKm
        self.timeMinutes = timeMinutes
    }

    public static func distance(km: Double) -> RunPlan {
        RunPlan(kind: .distance, distanceKm: km)
    }

    public static func time(minutes: Double) -> RunPlan {
        RunPlan(kind: .time, timeMinutes: minutes)
    }

    public static let open = RunPlan(kind: .open)

    /// Total target in meters (distance plans) or nil for others.
    public var totalMeters: Double? {
        kind == .distance ? distanceKm.map { $0 * 1000 } : nil
    }

    /// Total target in seconds (time plans) or nil for others.
    public var totalSeconds: Double? {
        kind == .time ? timeMinutes.map { $0 * 60 } : nil
    }

    /// Tight one-line description for diagnostics + watch UI.
    public var humanDescription: String {
        switch kind {
        case .distance:
            if let km = distanceKm { return "\(formatKm(km)) km" }
            return "distance"
        case .time:
            if let m = timeMinutes { return "\(Int(m)) min" }
            return "timed"
        case .open:
            return "open run"
        }
    }

    private func formatKm(_ km: Double) -> String {
        km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }
}
