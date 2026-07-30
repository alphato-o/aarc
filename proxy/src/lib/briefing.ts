/// HOME BASE BRIEFING — the agent's channel into the coaches' prompts.
///
/// Ricky and Jessica are LLM calls with no internet and no memory of the world.
/// The agent watching the run at home DOES have both. So the agent writes short
/// intel items here (POST /live/briefing) and every prompt builder folds the
/// fresh ones into the user prompt, tailored per voice.
///
/// This is deliberately the ONLY dynamic-world channel that isn't a keyless
/// feed: ambient.ts covers weather/AQI/headlines automatically, this covers the
/// things that need judgement — what's actually buzzing on X today, which
/// rival's round landed, what the run's own telemetry is doing.
///
/// Fails soft in every direction: no DB binding, no table, no rows, a thrown
/// query — all of them just omit the block. A dead briefing must never cost a
/// spoken line.

export interface BriefingEnv {
    DB?: D1Database;
}

export interface BriefingItem {
    kind: string;
    text: string;
}

const MEMO_TTL_MS = 30_000; // ~1 D1 read/min during a run; new items land fast
const MAX_ITEMS = 12;

/// How many items a single line actually SEES. Handing the model the whole
/// board makes it fixate on whichever item it finds most salient — a live test
/// had Ricky opening 3 lines in a row on the same Anthropic headline. Showing a
/// small ROTATED subset per call is the same trick jessicaDeck uses: the model
/// can only play the cards in its hand.
const HAND_SIZE = 3;

let memo: { at: number; items: BriefingItem[] } | null = null;

/// Fresh briefing items, newest first. Cheap enough to call per line.
export async function fetchBriefing(env: BriefingEnv): Promise<BriefingItem[]> {
    if (!env.DB) return [];
    if (memo && Date.now() - memo.at < MEMO_TTL_MS) return memo.items;
    try {
        const now = new Date().toISOString();
        const res = await env.DB
            .prepare(
                "SELECT kind, text FROM home_briefing WHERE expires_at IS NULL OR expires_at > ? ORDER BY id DESC LIMIT ?",
            )
            .bind(now, MAX_ITEMS)
            .all<{ kind: string; text: string }>();
        const items = (res.results ?? []).map((r) => ({ kind: r.kind, text: r.text }));
        memo = { at: Date.now(), items };
        return items;
    } catch {
        // Table missing (migration not applied yet) or D1 hiccup — stay silent.
        return [];
    }
}

/// Deal a rotated hand from the board so consecutive lines see different intel.
function dealHand(items: BriefingItem[]): BriefingItem[] {
    if (items.length <= HAND_SIZE) return items;
    const start = Math.floor(Math.random() * items.length);
    return Array.from({ length: HAND_SIZE }, (_, k) => items[(start + k) % items.length]!);
}

/// Per-voice framing. Both voices get the same FACTS; how they're told to use
/// them differs, because Ricky roasts with them and Jessica weaponises them.
function preamble(voice: "ricky" | "jessica"): string {
    const common =
        "HOME BASE BRIEFING — TODAY'S REAL WORLD, straight from the agent watching this run from the office back home. " +
        "These are TRUE, CURRENT facts you could not otherwise know (you have no internet). They are DATED TODAY and that is exactly what makes them land: " +
        "the runner is on a belt while this is happening out there.";
    if (voice === "jessica") {
        return `${common}
- Use them as AMMUNITION, not as news. You are not a newsreader and you never announce a headline. You take the fact and cut him with it: what someone else built today versus what he's doing right now, which is sweating.
- ONE item at most per line, and only when it sharpens the line. Most of your lines are still about the body, the money, the arrangement.
- Bend it to YOUR angle: what that man's money could buy, what his own money is currently renting, how the gap between them looks from where you're standing.
- NEVER quote the item verbatim and never say "apparently" or "I hear" — you know things, you don't cite sources.`;
    }
    return `${common}
- This is PRIME roast material — the outside world moving while he jogs on the spot. Fuse it with what he's actually doing: the number on the belt, the pace, the personal troll bullets.
- Do NOT read it out as a headline or do a news bulletin. Take the FACT and build a joke around it. The item is the hook, never the punchline.
- Use it in maybe one line in four — a surprise roast, a quiet stretch, a per-km variant. Spread them out; don't dump the whole briefing in one line.
- NEVER quote an item word-for-word.`;
}

/// The block to append to a user prompt, or "" when there's nothing to say.
export function formatBriefing(items: BriefingItem[], voice: "ricky" | "jessica"): string {
    const hand = dealHand(items);
    if (hand.length === 0) return "";
    const lines = [preamble(voice), ""];
    for (const it of hand) {
        lines.push(`- [${it.kind}] ${it.text}`);
    }
    return lines.join("\n");
}

/// Fetch + format + push onto a prompt line array.
///
/// `chance` gates whether the block is included AT ALL on this call. Telling a
/// model "use this in one line in four" does not work — a live sweep had the
/// briefing land in 8 of 8 lines and the run started sounding like a tech news
/// bulletin. Withholding the material is the only reliable rate limit: if it
/// isn't in the prompt, it can't be in the line.
///
/// Pass `chance: 1` for the BATCH generators (generate-script, roast-pool) —
/// they make one call and emit many lines, so their own prompt-level "spread
/// them out" rule is what applies there.
export async function pushBriefingBlock(
    lines: string[],
    env: BriefingEnv,
    voice: "ricky" | "jessica",
    opts: { chance?: number } = {},
): Promise<void> {
    const chance = opts.chance ?? 0.35;
    if (chance < 1 && Math.random() >= chance) return;
    const block = formatBriefing(await fetchBriefing(env), voice);
    if (block) {
        lines.push("");
        lines.push(block);
    }
}
