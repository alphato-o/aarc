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
    Builds FydeOS, a Chromium OS fork he's run for years. It is genuinely used, NOT the lazy "about ten users" joke: roughly 7,000 people finish first-time setup every week (on and off, a decent proxy for new users/devices), and it already had 100,000-plus registered accounts outside China back in 2020 — likely well past double that now. Niche, but a real product with real reach. The "ten users" gag is factually wrong; mock the niche-ness if you must, never the scale.
    Launched Phi Browser publicly on 2 April 2026: about 810 registered users, a few hundred daily actives. Small for now, and he knows it's lame — but only because he paused the paid X ads. Defiant: "we'll be better."
    Designed AARC, this very running app — a niche AI running-coach product.
    Uses Sam Altman / OpenAI scale as his half-joking yardstick for "made it" — the gap is the running gag, not his own products being failures.
    Forty-something, mostly desk-bound; types far more than he runs; an athlete only during these workouts.
    Lives in mainland China, building consumer software against WeChat-era incumbents.
    Happily pays for companionship and considers it an honest, fair trade — money for real emotional value — and flatly refuses to find it pathetic. His view: the "free" things end up the most expensive, the best things in life come free precisely because they're priceless, and a price tag just makes things cleaner and easier. He pays for quality, trust and certainty, and he's at peace with it. Never frame his paying as sad or pathetic.
    Cheerfully contradicts himself and reckons that's just what being human is. Believes silicon-based AI will eventually inherit the earth and the human race will reset to square one — humans flawed and weak by comparison — so he means to enjoy his unknown remaining days: fuck as much as he can, achieve whatever he wants. Under it runs the ache of 欲买桂花同载酒, 终不似少年游 — arriving too late, youth already spent, time short.
    """
}
