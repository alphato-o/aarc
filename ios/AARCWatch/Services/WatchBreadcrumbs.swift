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

    /// Full-history log file in the app container — pullable from a Mac
    /// with `devicectl device copy from … appDataContainer …` without
    /// touching the watch. The UserDefaults ring is the on-wrist view;
    /// this file is the forensic record.
    nonisolated static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("watchlog.txt")
    }()

    func drop(_ event: String) {
        let line = "\(formatter.string(from: .now)) \(event)"
        entries.append(line)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        UserDefaults.standard.set(entries, forKey: Self.key)
        appendToFile(line)
    }

    private func appendToFile(_ line: String) {
        let data = (line + "\n").data(using: .utf8)!
        if let handle = try? FileHandle(forWritingTo: Self.fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.fileURL)
        }
        // Trim if it grows past ~256 KB (keep the newest half).
        if let size = try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)[.size] as? Int,
           size > 256_000,
           let content = try? String(contentsOf: Self.fileURL, encoding: .utf8) {
            let tail = String(content.suffix(128_000))
            try? tail.data(using: .utf8)?.write(to: Self.fileURL)
        }
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Most recent first, for display.
    var recentFirst: [String] { entries.reversed() }
}
