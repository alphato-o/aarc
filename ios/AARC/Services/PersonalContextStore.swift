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

    /// Parsed bullets for sending to the proxy. Strips empty lines and
    /// excess whitespace; caps at 20 bullets so we don't blow the
    /// system-prompt cache budget on chatty inputs.
    var bullets: [String] {
        let trimmed = rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(trimmed.prefix(20))
    }

    /// The bundled default. Edit-friendly: each line is one trolling
    /// hook the coach can pull on. Tone is "things the runner would
    /// say about themselves at 2am" — self-deprecating + specific.
    private static let defaultBio = """
    Product manager. Builds things nobody asks for. Currently runs FydeOS — a Chromium OS fork with maybe 10 actual daily users despite years of work.
    Side project Phi Browser. It's not going to be a thing. He keeps shipping anyway.
    Designed AARC, this running app. Generative AI coach for runners. Niche of a niche of nothing.
    Will never be Sam Altman. Will never be anywhere near Sam Altman. The closest he'll get to OpenAI is the API bill.
    Whole product career feels like one long apology. LinkedIn is a graveyard of pivots.
    Runs occasionally, mostly types at a computer. Out here pretending he's an athlete because the watch said so.
    Lives in mainland China. Building consumer software for a market that already has WeChat. Genuinely.
    Forty-something next birthday, still chasing "the big break". It is not coming.
    """
}
