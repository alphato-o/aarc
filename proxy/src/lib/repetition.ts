/**
 * Cross-line repetition guard. The anti-repeat machinery already lists the
 * recently-spoken lines and tells the model "don't echo them", but the real run
 * (BFDD0366) showed that's not enough: the coaches fixate on UNITS across lines
 * — "because unlike …" ×14, "little twat/prick" ×14, "forty minutes" ×8,
 * "until finally" ×7, a venue name ×11. The model re-reaches for the same word,
 * connector, or template even while "varying" the sentence.
 *
 * This extracts the over-used units from the recent window and hands the model a
 * hard, explicit DO-NOT-REUSE list — deterministic, not a buried plea. Cheap
 * (pure string work) and self-tuning: only fires on units actually being
 * over-leaned-on right now.
 */

// Pure function words + a few run-context staples that are EXPECTED to recur
// (we don't want to ban "kilometre" off a coach mid-run). Distinctive content
// words and connectors are deliberately NOT here — those are the tells.
const STOP = new Set([
    "the", "and", "but", "for", "are", "was", "you", "your", "youre", "with",
    "that", "this", "have", "has", "had", "not", "from", "they", "them", "then",
    "than", "what", "when", "well", "into", "onto", "like", "just", "still",
    "here", "there", "their", "about", "over", "been", "will", "would", "could",
    "its", "it's", "his", "her", "she", "him", "out", "now", "got", "get",
    "one", "two", "all", "can", "cant", "dont", "didnt", "isnt", "more", "some",
    "kilometre", "kilometres", "kilometer", "kilometers", "run", "running",
    // 3-letter function words (min token length is 3 so AQI-class tokens are
    // catchable; these must not trip the ban).
    "who", "why", "how", "any", "our", "off", "own", "too", "yet", "let",
    "did", "does", "very", "much", "many", "each", "even", "only", "also",
    // persona catchphrases — signature ticks, not fixation
    "mate", "love", "darling", "christ", "god",
    // the runner's own name. It MUST never reach the ban list: that block tells
    // the model "this hook is spent, find another angle", and the only other
    // angle for a name is third person or no address at all — the exact failure
    // we just fixed. Density is handled by buildNameRation below instead.
    "alpha", "wensong",
]);

const RUNNER_NAMES = ["alpha", "wensong"];

/// Ration the runner's NAME rather than banning it.
///
/// Jessica was slipping into the third person ("he", "the poor lamb"), which
/// made the runner a bystander on his own run. The fix told her to address him
/// by name — and she promptly used it in 100% of lines, i.e. reinvented the
/// "darling" tic. This counts name usage in the recent window and, when it gets
/// dense, tells her to drop the name for ONE line while keeping the
/// second-person address intact. Deterministic, self-tuning, and it can never
/// push her back toward talking about him.
/// The recent-lines window is SHARED between both voices (the runner hears one
/// stream), so a naive ration lets whoever speaks first spend the whole name
/// budget. A live sim showed exactly that: Ricky named him in 8 of 10 lines and
/// Jessica got down to 1 in 10 — the precise inversion of what the founder
/// asked for, since using his name is HER fix. So the two voices ration at
/// different thresholds:
///   jessica — the name is her intimacy and the point of the fix. Only backs
///             off when the last TWO lines both used it (≈1 line in 2).
///   ricky   — "mate" is his instinct and the name is a rare change of gear.
///             Backs off whenever EITHER of the last two lines used it, which
///             also means he yields the name to Jessica by design.
export function buildNameRation(
    recentLines: string[] | undefined,
    voice: "ricky" | "jessica",
): string | null {
    if (!recentLines || recentLines.length === 0) return null;
    const named = (l: string) => {
        const t = l.toLowerCase();
        return RUNNER_NAMES.some((n) => t.includes(n));
    };
    const last2 = recentLines.slice(-2);
    const hits2 = last2.filter(named).length;
    const hits3 = recentLines.slice(-3).filter(named).length;

    let why: string | null = null;
    if (voice === "ricky") {
        if (hits2 >= 1) {
            why = "his name has just been spoken in the last line or two — and for you it's a rare change of gear, not a habit";
        }
    } else if (hits3 >= 2) {
        // Deliberately looser than Ricky's: she SHOULD be the one using it. At
        // 2-of-3 she lands around every other line, which reads as intimacy.
        // (A stricter 2-of-2 rule was tried and left her at 100% — with Ricky
        // suppressed, two named lines never sat adjacent to trigger it.)
        why = `his name appears in ${hits3} of the last 3 spoken lines, and naming him every single time turns the intimacy into the next "darling"`;
    }
    if (!why) return null;

    return `NAME RATION (deterministic, and it OVERRIDES the "one line in three" guidance): ${why}. THIS line uses NO name and NO endearment at all — pure second person, aimed straight at him. Do NOT compensate by describing him in the third person; "you" is still the only way you refer to him.`;
}

/// Build a DO-NOT-REUSE block from the recent lines, or null if nothing is being
/// over-used yet (or there's too little history to tell).
export function buildRepetitionBan(recentLines: string[] | undefined): string | null {
    if (!recentLines || recentLines.length < 3) return null;

    // Strip audio tags ([sighs]) and lowercase so "Darling"/"[giggles] darling"
    // collapse to one unit.
    const clean = recentLines.map((l) => l.replace(/\[[^\]]*\]/g, " ").toLowerCase());

    const wordLines = new Map<string, Set<number>>(); // word -> distinct line indices
    const bigramCount = new Map<string, number>();

    clean.forEach((line, i) => {
        // Digits included so number-facts ("152", "97") count as tokens; the
        // v1 pattern missed them and the coaches milked the same number for a
        // whole run. Min length 3 so short distinctive tokens (AQI) count too.
        const words = line.match(/[a-z0-9']{3,}/g) ?? [];
        for (const w of words) {
            if (STOP.has(w)) continue;
            if (!wordLines.has(w)) wordLines.set(w, new Set());
            wordLines.get(w)!.add(i);
        }
        for (let k = 0; k < words.length - 1; k++) {
            const a = words[k]!, b = words[k + 1]!;
            // a bigram is only interesting if at least one half is contentful
            if (STOP.has(a) && STOP.has(b)) continue;
            const bg = `${a} ${b}`;
            bigramCount.set(bg, (bigramCount.get(bg) ?? 0) + 1);
        }
    });

    const banned: string[] = [];
    // A content word leaned on across ≥3 distinct recent lines.
    for (const [w, lines] of wordLines) if (lines.size >= 3) banned.push(w);
    // A repeated phrase. Distinctive bigrams (a long content token in them,
    // e.g. "six layovers", "forty quid") get banned at TWO uses — the field
    // case milked one personal-note hook 7 times, and by the second repeat it
    // already reads mechanical. Ordinary bigrams still need 3.
    for (const [bg, c] of bigramCount) {
        const distinctive = bg.split(" ").some((t) => t.length >= 6 && !STOP.has(t));
        if (c >= (distinctive ? 2 : 3)) banned.push(`"${bg}"`);
    }

    if (banned.length === 0) return null;
    // De-dup (a banned bigram may also contain a banned word) and cap.
    const top = [...new Set(banned)].slice(0, 14);
    return [
        "OVERUSED ALREADY THIS RUN — you have leaned on these exact words, numbers, or phrases too many times. HARD RULES for THIS line: (1) do NOT use any item below, not even reworded around the same fact or hook (if \"six layovers\" is banned, the whole layover story is spent — find a DIFFERENT angle, don't say \"half a dozen connections\"); (2) avoid the repeated sentence SHAPE too (a contrast connector, a diminutive-insult template); (3) if the banned item came from the runner's personal notes, that bullet is USED UP for now — pick a different bullet or none. Repeating a hook is the single most mechanical thing you can do:",
        top.join(", "),
    ].join("\n");
}
