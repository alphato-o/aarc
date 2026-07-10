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
]);

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
