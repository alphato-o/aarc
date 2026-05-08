import Foundation

/// Deterministic, mildly-offensive run titles in the Hobson Insult Generator
/// vein. Same run always gets the same title (seeded by the run's UUID), so
/// the History list is stable across renders. Vibe: Shakespearean /
/// Monty Python — never actually offensive, just mock-archaic.
public enum RunTitleGenerator {
    public static func title(forRunId runId: UUID, startedAt: Date, runType: RunType) -> String {
        var rng = SeededRNG(seed: runId.uuidString.hashValue)
        let adj1 = adjectives.randomElement(using: &rng) ?? "festering"
        let noun1 = nouns.randomElement(using: &rng) ?? "knave"
        let adj2 = adjectives.randomElement(using: &rng) ?? "blithering"
        let gerund = gerunds.randomElement(using: &rng) ?? "wittering"
        let plural = pluralNouns.randomElement(using: &rng) ?? "weasels"

        let kind = (runType == .treadmill) ? "treadmill" : "run"
        let dayPeriod = Self.dayPeriod(for: startedAt)
        let raw = "\(adj1) \(noun1) of \(adj2) \(gerund) \(plural)'s \(kind) at \(dayPeriod)"
        return raw.capitalizingFirstLetter()
    }

    // MARK: - Word lists (kept Shakespearean / mock-archaic on purpose)

    private static let adjectives = [
        "festering", "blithering", "snivelling", "smarmy", "churlish",
        "witless", "spineless", "ham-fisted", "hapless", "wretched",
        "gormless", "bumbling", "addled", "addle-pated", "feckless",
        "dim-witted", "lily-livered", "pestilential", "scurrilous",
        "weaselly", "porcine", "vainglorious", "cantankerous", "noxious",
        "preposterous", "rancid", "obstreperous", "impudent", "indolent",
        "pernicious", "puffed-up", "moth-eaten", "rheumy-eyed",
        "unwashed", "ill-bred",
    ]

    private static let nouns = [
        "codpiece", "varlet", "knave", "scoundrel", "miscreant",
        "blackguard", "ne'er-do-well", "dunderhead", "ninnyhammer", "cur",
        "lout", "wastrel", "goon", "lummox", "fopdoodle", "scallywag",
        "tosspot", "bounder", "buffoon", "harpy", "rapscallion",
        "flibbertigibbet", "lickspittle", "milksop", "popinjay",
        "pillock", "halfwit", "scaramouche", "gadabout", "loafer",
    ]

    private static let gerunds = [
        "interfering", "dithering", "wittering", "blathering", "grovelling",
        "faffing", "pottering", "gawping", "wheedling", "sniggering",
        "skulking", "slouching", "wallowing", "gibbering", "dawdling",
        "preening", "kowtowing", "grandstanding", "snorting", "harrumphing",
        "moping", "fretting", "blustering", "moaning", "whingeing",
    ]

    private static let pluralNouns = [
        "horses", "weasels", "ferrets", "baboons", "oafs", "bumpkins",
        "halfwits", "magpies", "yokels", "scoundrels", "vagabonds",
        "newts", "toads", "ne'er-do-wells", "blackguards", "barnacles",
        "dunderheads", "popinjays", "scarecrows", "stoats", "muppets",
        "owls", "geese", "wombats", "donkeys", "alpacas",
    ]

    // MARK: - Time-of-day phrasing

    static func dayPeriod(for date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: date)
        let weekdayName = cal.weekdaySymbols[(weekday - 1) % 7]
        let hour = cal.component(.hour, from: date)
        let period: String
        switch hour {
        case 5..<12: period = "morning"
        case 12..<17: period = "afternoon"
        case 17..<21: period = "evening"
        default: period = "night"
        }
        return "\(weekdayName) \(period)"
    }
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

private extension String {
    func capitalizingFirstLetter() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
