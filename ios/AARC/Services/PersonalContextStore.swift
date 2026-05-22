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
