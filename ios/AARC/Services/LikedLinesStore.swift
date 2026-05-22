import Foundation
import Observation

/// Persistent record of coach lines the runner has tapped the heart
/// on. The store has two jobs:
///
///   1. Tell the in-run subtitle UI whether a given line is liked
///      (so the heart icon renders pre-filled if the same line gets
///      replayed later).
///   2. Hand the proxy a short list of liked exemplars as
///      "calibration-only, never copy" vibe references — so as the
///      runner curates favorites, the model gets a clearer signal on
///      what works for them without regurgitating.
///
/// Stored as plain JSON in UserDefaults. Solo-runner product, fewer
/// than ~hundreds of liked lines expected — overkill to put behind
/// SwiftData. Will revisit if the corpus grows.
@Observable
@MainActor
final class LikedLinesStore {
    static let shared = LikedLinesStore()

    struct LikedLine: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let text: String
        /// e.g., "script:per_km", "coach:hr_spike", "coach:music_riff",
        /// "coach:opener" — same diagnostic source string used by
        /// VoiceFeedbackQueue.
        let source: String?
        let personalityId: String
        let likedAt: Date
    }

    private(set) var lines: [LikedLine] = []

    private static let kKey = "aarc.likedLines.v1"

    init() {
        load()
    }

    func isLiked(text: String) -> Bool {
        let needle = Self.normalize(text)
        return lines.contains { Self.normalize($0.text) == needle }
    }

    @discardableResult
    func like(text: String, source: String?, personalityId: String) -> Bool {
        guard !text.isEmpty, !isLiked(text: text) else { return false }
        lines.append(LikedLine(
            id: UUID(),
            text: text,
            source: source,
            personalityId: personalityId,
            likedAt: .now
        ))
        save()
        return true
    }

    func unlike(text: String) {
        let needle = Self.normalize(text)
        let before = lines.count
        lines.removeAll { Self.normalize($0.text) == needle }
        if lines.count != before { save() }
    }

    /// Most-recent N liked lines for a given personality, suitable
    /// for sending to the proxy as "vibe-only, do not copy" exemplars.
    /// Cap is deliberate: every additional bullet expands the system
    /// prompt and breaks the cache key. 12 lines is enough texture
    /// without bloating the cache.
    func vibeExemplars(personalityId: String, max: Int = 12) -> [String] {
        lines
            .filter { $0.personalityId == personalityId }
            .sorted { $0.likedAt > $1.likedAt }
            .prefix(max)
            .map(\.text)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.kKey) else { return }
        if let decoded = try? JSONDecoder().decode([LikedLine].self, from: data) {
            lines = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        UserDefaults.standard.set(data, forKey: Self.kKey)
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
