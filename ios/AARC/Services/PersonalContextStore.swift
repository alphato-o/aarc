import Foundation
import Observation

/// Short, blunt bullets describing the runner that the coach can weave
/// into roasts. Deliberately *not* "user memory" in the Phase 2 sense
/// (which will be AI-extracted facts about training preferences) —
/// this is the founder's standing bio: the things they actively want
/// the coach to troll them about during a run.
///
/// Persisted as a single newline-separated string in UserDefaults so
/// the Settings UI can hand-edit it. Splits into bullets at read time.
/// Empty string → use the bundled default (Alpha's bio).
@Observable
@MainActor
final class PersonalContextStore {
    static let shared = PersonalContextStore()

    private static let kKey = "aarc.personalContext.bullets"

    /// Raw multiline text as the user sees it in Settings. Each non-empty
    /// line becomes one bullet sent to the proxy.
    var rawText: String {
        didSet { UserDefaults.standard.set(rawText, forKey: Self.kKey) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.kKey) ?? ""
        self.rawText = stored.isEmpty ? Self.defaultBio : stored
    }

    /// All non-empty bullets, in author order. Not what we send to the
    /// proxy — see `bullets` for the per-run rotated subset and
    /// `allBullets` if you genuinely need everything (e.g. Settings UI).
    var allBullets: [String] {
        rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Hard cap on bullets sent to the proxy per call. Matches the
    /// proxy's Zod cap; keeps the system-prompt cache budget bounded.
    static let perCallCap = 20

    /// Bullets to send for this call. If the author has more than
    /// `perCallCap`, we pick a deterministic subset seeded by
    /// `rotationSeed` — stable for the lifetime of one run (cache hits
    /// across opener → script → dynamic-line → music-comment calls),
    /// but different across runs so the troll cycles through the whole
    /// pool over time instead of always firing the same first 20.
    var bullets: [String] {
        bullets(seed: rotationSeed)
    }

    /// Explicit-seed variant for tests / previews.
    func bullets(seed: UInt64) -> [String] {
        let all = allBullets
        guard all.count > Self.perCallCap else { return all }
        // Seeded shuffle of indices, then take the first N. We sort by
        // a per-index hash rather than running a Fisher-Yates with a
        // mutable RNG, because it's the same idea with simpler code
        // and identical determinism for a given seed.
        let pickedIndices = all.indices
            .map { (idx: $0, key: Self.hash(seed: seed, index: UInt64($0))) }
            .sorted { $0.key < $1.key }
            .prefix(Self.perCallCap)
            .map(\.idx)
            .sorted()  // preserve author order in the final subset
        return pickedIndices.map { all[$0] }
    }

    /// SplitMix64-style mixer: deterministic per (seed, index) pair, no
    /// RNG state to carry around. Plenty of entropy for shuffling.
    private static func hash(seed: UInt64, index: UInt64) -> UInt64 {
        var z = seed &+ (index &* 0x9E3779B97F4A7C15)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Seed used by `bullets` when no explicit seed is provided. Cleared
    /// when a new run starts, so each run picks a fresh rotation; calls
    /// within the same run keep hitting the prompt cache.
    private(set) var rotationSeed: UInt64 = .random(in: .min ... .max)

    /// Call at the start of a run to reshuffle the bullet pool.
    func rerollRotation() {
        rotationSeed = .random(in: .min ... .max)
    }

    /// The bundled default. Each line is a FACT about the runner the
    /// coach can mine — not a finished punchline. The proxy prompt is
    /// strict about re-phrasing every time, so bullets that read more
    /// like "what we know" than "what to say" produce more variation.
    private static let defaultBio = """
    Builds FydeOS — a Chromium OS fork. Has worked on it for years; current user base is very small (single-digit-thousands at best, often joked about as ~10).
    Side project: Phi Browser. New, no traction, openly admitted to not going anywhere.
    Designed AARC, this running app. Niche AI-coaching product for runners.
    Compares himself unfavourably to Sam Altman / OpenAI scale; treats that as a running joke.
    Product-management career he describes as a series of pivots that haven't landed.
    Runs occasionally; mostly desk-bound. Forty-something. Mostly a typist pretending to be an athlete during workouts.
    Lives in mainland China. Building consumer software for a market dominated by WeChat-era incumbents.
    """
}
