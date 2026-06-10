import Foundation
import Observation

/// Persisted launch/start breadcrumbs, readable ON THE WATCH. Device
/// logs from the watch are painful to collect (Xcode tunnel required),
/// which made the phone-initiated launch failures undiagnosable in the
/// field. Every interesting lifecycle event drops a timestamped crumb
/// into a UserDefaults ring; the idle screen's debug section renders
/// the trail. After a failed handover, the answer is on the wrist:
/// if `launch` is missing the app never launched (watchOS force-quit
/// penalty / old build); if `launch` is there but `handle(cfg)` isn't,
/// the delegate adaptor didn't deliver; and so on.
@Observable
@MainActor
final class WatchBreadcrumbs {
    static let shared = WatchBreadcrumbs()

    private static let key = "aarc.breadcrumbs"
    private static let capacity = 40

    private(set) var entries: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        entries = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func drop(_ event: String) {
        let line = "\(formatter.string(from: .now)) \(event)"
        entries.append(line)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        UserDefaults.standard.set(entries, forKey: Self.key)
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Most recent first, for display.
    var recentFirst: [String] { entries.reversed() }
}
