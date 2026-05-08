import Foundation

/// Deterministic, mildly-offensive run titles in the Hobson Insult Generator
/// vein. Same run always reads the same title (seeded by the run's UUID).
/// Format: `"<RunType> run like a <noun> of <plural>"`. Mock-archaic and
/// mock-Cockney rather than actually offensive.
///
/// Examples:
/// - "Treadmill run like a diver of bollocks"
/// - "Outdoor run like a knave of magpies"
public enum RunTitleGenerator {
    public static func title(forRunId runId: UUID, runType: RunType) -> String {
        var rng = SeededRNG(seed: runId.uuidString.hashValue)
        let modifier = modifiers.randomElement(using: &rng) ?? "diver"
        let plural = pluralNouns.randomElement(using: &rng) ?? "bollocks"
        let prefix = (runType == .treadmill) ? "Treadmill" : "Outdoor"
        return "\(prefix) run like a \(modifier) of \(plural)"
    }

    /// Singular nouns that read naturally in the "like a <X> of …" slot.
    private static let modifiers = [
        "diver", "muppet", "knave", "scoundrel", "halfwit", "pillock",
        "berk", "wastrel", "twit", "buffoon", "popinjay", "fopdoodle",
        "dunderhead", "lickspittle", "lout", "nincompoop", "simpleton",
        "dolt", "ninnyhammer", "scallywag", "bumpkin", "plonker", "wally",
        "gadabout", "rapscallion", "harpy", "blackguard", "tosspot",
    ]

    /// Plural nouns for the "… of <Y>" slot.
    private static let pluralNouns = [
        "bollocks", "weasels", "ferrets", "muppets", "pillocks", "berks",
        "halfwits", "knaves", "swines", "magpies", "dunderheads",
        "scarecrows", "donkeys", "oafs", "bumpkins", "fools", "twits",
        "gits", "geese", "plonkers", "toads", "wombats", "scallywags",
        "blackguards", "scoundrels", "ninnyhammers", "popinjays",
    ]
}

// MARK: - Seeded RNG (splitmix64)

/// Stable RNG so the same UUID always produces the same words.
/// Standard library's `SystemRandomNumberGenerator` is unseedable.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed))
        if state == 0 { state = 0x9E3779B97F4A7C15 }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
