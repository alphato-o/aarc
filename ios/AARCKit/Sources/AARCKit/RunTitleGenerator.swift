import Foundation

/// Deterministic, mildly-offensive run titles in the Hobson Insult Generator
/// vein. Same run always reads the same title (seeded by the run's UUID bytes
/// — stable across launches, unlike `String.hashValue`).
///
/// Format: `"<Weekday> <daypart> <runtype> run like a <noun> <doing-something>"`.
///
/// Examples:
/// - "Sunday afternoon outdoor run like a halfwit chopping onions"
/// - "Tuesday morning treadmill run like a plonker herding cats"
public enum RunTitleGenerator {
    public static func title(forRunId runId: UUID, date: Date, runType: RunType) -> String {
        var rng = SeededRNG(seed: stableSeed(runId))
        let modifier = modifiers.randomElement(using: &rng) ?? "halfwit"
        let activity = activities.randomElement(using: &rng) ?? "chopping onions"
        let kind = runType == .treadmill ? "treadmill" : "outdoor"
        return "\(weekday(date)) \(daypart(date)) \(kind) run like a \(modifier) \(activity)"
    }

    /// Filesystem/share-safe slug of the title (for naming exported files).
    public static func fileName(forRunId runId: UUID, date: Date, runType: RunType) -> String {
        let raw = title(forRunId: runId, date: date, runType: runType)
        let slug = raw.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "aarc-run" : slug
    }

    // MARK: - Date pieces

    private static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private static func daypart(_ date: Date) -> String {
        let h = Calendar(identifier: .gregorian).component(.hour, from: date)
        switch h {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "late-night"
        }
    }

    /// Stable 64-bit seed from the UUID's 16 bytes (no `String.hashValue`).
    private static func stableSeed(_ id: UUID) -> UInt64 {
        let b = id.uuid
        let bytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                     b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        var h: UInt64 = 0xCBF29CE484222325          // FNV-1a
        for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100000001B3 }
        return h
    }

    /// Singular nouns that read naturally in the "like a <X> …" slot.
    private static let modifiers = [
        "diver", "muppet", "knave", "scoundrel", "halfwit", "pillock",
        "berk", "wastrel", "twit", "buffoon", "popinjay", "fopdoodle",
        "dunderhead", "lickspittle", "lout", "nincompoop", "simpleton",
        "dolt", "ninnyhammer", "scallywag", "bumpkin", "plonker", "wally",
        "gadabout", "rapscallion", "harpy", "blackguard", "tosspot",
    ]

    /// Gerund mini-scenes for the "… <doing something absurd>" slot.
    private static let activities = [
        "chopping onions", "herding cats", "wrestling a duvet", "parking a lorry",
        "fighting a revolving door", "assembling flat-pack furniture", "folding a fitted sheet",
        "chasing a runaway trolley", "arguing with a vending machine", "untangling fairy lights",
        "missing the last bus", "losing a thumb war", "buttering toast in mittens",
        "running from the bins", "explaining crypto at a wedding", "queuing at the wrong counter",
        "outrunning a wasp", "dodging a charity mugger", "carrying too many bags",
        "reversing into a hedge", "tripping over a cat", "spilling a pint",
        "negotiating with a toddler", "escaping a timeshare pitch", "wading through treacle",
    ]
}

// MARK: - Seeded RNG (splitmix64)

/// Stable RNG so the same UUID always produces the same words.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
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
