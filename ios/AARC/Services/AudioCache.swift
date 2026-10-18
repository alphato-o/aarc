import Foundation
import CryptoKit

/// On-disk cache of TTS audio, keyed by hash(voiceId + text). Lives in
/// the app's Caches directory so iOS can reclaim it under disk pressure;
/// for race-day pre-renders we'll move to a permanent location in §3.
actor AudioCache {
    static let shared = AudioCache()

    private let directory: URL
    /// Lines the run cannot do without offline (race pack, roast pool):
    /// Application Support, which iOS never reclaims, unlike Caches.
    private let pinned: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directory = caches.appendingPathComponent("AARC/tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var pinnedDir = support.appendingPathComponent("AARC/tts-pinned", isDirectory: true)
        try? FileManager.default.createDirectory(at: pinnedDir, withIntermediateDirectories: true)
        var noBackup = URLResourceValues(); noBackup.isExcludedFromBackup = true
        try? pinnedDir.setResourceValues(noBackup)
        self.pinned = pinnedDir
    }

    /// Keep this entry where iOS cannot purge it. True if it is now pinned.
    @discardableResult
    func pin(key: String) -> Bool {
        let dst = pinned.appendingPathComponent("\(key).mp3")
        if FileManager.default.fileExists(atPath: dst.path) { return true }
        let src = path(forKey: key)
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        return (try? FileManager.default.copyItem(at: src, to: dst)) != nil
    }

    func unpin(key: String) {
        try? FileManager.default.removeItem(at: pinned.appendingPathComponent("\(key).mp3"))
    }

    /// Stable hash key. Uses SHA-256 over `voiceId\u{1}text` so that
    /// changing either invalidates the entry.
    nonisolated static func key(voiceId: String, text: String) -> String {
        let combined = "\(voiceId)\u{1}\(text)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// File URL for a cached entry, or nil if not on disk.
    func url(forKey key: String) -> URL? {
        let url = path(forKey: key)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let kept = pinned.appendingPathComponent("\(key).mp3")
        return FileManager.default.fileExists(atPath: kept.path) ? kept : nil
    }

    /// Persist bytes for a key. Atomic write (tmp + rename) so we never
    /// hand back a half-written file.
    func store(data: Data, forKey key: String) throws -> URL {
        let url = path(forKey: key)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Wipe the entire cache (used during dev / Settings → "Clear cache").
    func purge() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Approximate disk usage in bytes — for diagnostic UIs.
    func sizeBytes() -> Int64 {
        let resourceKeys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys
        ) {
            for case let fileURL as URL in enumerator {
                if let r = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                   r.isRegularFile == true,
                   let size = r.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private func path(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).mp3")
    }
}
