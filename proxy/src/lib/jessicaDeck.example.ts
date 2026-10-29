/// STARTER content deck for the second voice. `npm install` copies this to
/// jessicaDeck.ts (gitignored) when that file is missing. Each line, the
/// second voice is dealt a small fresh hand of cards to improvise from, so it
/// varies by construction instead of by prompt bans. The aarc-bootstrap skill
/// rewrites the cards for your own character; keep the exported names.

export type DeckDim = "topic" | "angle" | "image" | "mood";

const DECK: Record<DeckDim, string[]> = {
    topic: [
        "the runner's shoes",
        "what they had for breakfast",
        "the playlist choices",
        "the weather",
        "Ricky's own fitness, or lack of it",
        "people on the pavement watching",
        "the plan they swore they would stick to",
        "how they will describe this run to friends later",
    ],
    angle: [
        "take Ricky's side, then betray him",
        "defend the runner against Ricky",
        "pretend to misunderstand Ricky on purpose",
        "a fake statistic, delivered with total confidence",
        "a tiny story from your own day",
    ],
    image: [
        "a pigeon that has given up on life",
        "a sofa calling their name",
        "a marching band nobody asked for",
        "a sports commentator losing his voice",
        "a cat refusing to get off a keyboard",
    ],
    mood: ["amused", "mock-outraged", "proud and hiding it", "conspiratorial", "unimpressed"],
};

export type DeckMode = "quip" | "medium" | "indulgent" | "summary";

function dimsFor(mode: DeckMode, ordinal: number): DeckDim[] {
    switch (mode) {
        case "quip": {
            const rot: DeckDim[] = ["topic", "image", "angle", "mood"];
            return [rot[((ordinal % rot.length) + rot.length) % rot.length]!];
        }
        case "medium":
            return ["topic", "angle"];
        case "indulgent":
            return ["topic", "angle", "image", "mood"];
        case "summary":
            return ["mood", "angle"];
    }
}

function pick(dim: DeckDim, seed: number, ordinal: number): string {
    const cards = DECK[dim];
    const i = Math.abs((seed * 31 + ordinal * 17 + dim.length * 7) | 0) % cards.length;
    return cards[i]!;
}

export function deckBlock(mode: DeckMode, seed: number, ordinal: number): string {
    const hand = dimsFor(mode, ordinal).map((d) => `  - ${d}: ${pick(d, seed, ordinal)}`);
    return `YOUR DECK THIS LINE: fresh cards to PLAY, not recite:
${hand.join("\n")}
Use one or combine two, improvise something new.`;
}
