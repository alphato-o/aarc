import { callLLM, describeUpstreamError, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";

export type Env = LLMEnv & SentryEnv;

/// Rank the venue candidates the phone found, so the runner is asked about the
/// places he could plausibly BE before the places he never would.
///
/// Founder, 2026-08-17: "before park hyatt is found, there were tons of rubbish
/// places that i will never likely to be in, those cheap lodges or hostles...
/// you should rank them from top to bottom." On the 13 Aug run Park Hyatt
/// Beijing came 15th of 20 — he tapped "No" fourteen times to reach it —
/// because MapKit ranks purely by distance and a big hotel's map pin sits at
/// its tower entrance while a hostel's sits on the street.
///
/// Deliberately NOT a hardcoded brand list, per his follow-up ("do not hard
/// wire anything, that is my whole point"). A baked-in table of luxury chains
/// would be wrong the moment he travels somewhere it doesn't cover, and it
/// cannot tell a grand old independent hotel from a budget one. A model knows
/// what these places are, in any city, in any language — so ASK it, and send
/// only the names we were given.
const SYSTEM = `You rank places a specific runner might currently be standing in.

WHO HE IS: a well-paid founder who travels constantly and stays in genuinely
good hotels. He uses the hotel's own gym. He would never be found training in a
hostel, a youth lodge, a budget chain, a serviced apartment, a capsule hotel or
a roadside inn.

TASK: you are given the venue names a phone found near him, in whatever
language they came in. Return them REORDERED, most likely first.

RANK BY:
1. Luxury and high-end international or independent hotels first — the kind
   with a proper fitness centre.
2. Then solid upper-mid business hotels.
3. Then standalone commercial gyms and fitness studios (plausible, just less
   likely than his own hotel).
4. Budget chains, hostels, youth//guesthouse/homestay, serviced apartments and
   capsule hotels LAST. Never drop them — he might be somewhere unexpected —
   just put them where they belong.

Judge each name on its own merits and on what you know of that specific place
in that specific city. Do not apply a generic keyword rule.

OUTPUT: strict JSON only, no prose, no fences:
{"ranked":["name","name",...]}
Every input name must appear EXACTLY once, character-for-character as given.`;

interface Body {
    candidates?: string[];
    city?: string;
}

export async function rankVenuesHandler(request: Request, env: Env): Promise<Response> {
    let body: Body;
    try {
        body = await request.json<Body>();
    } catch {
        return json({ ok: false, error: "invalid json" }, 400);
    }
    const candidates = (body.candidates ?? []).map((c) => String(c).trim()).filter(Boolean);
    if (candidates.length === 0) return json({ ok: false, error: "candidates required" }, 400);
    // Nothing to reorder — don't pay for a round trip mid-run.
    if (candidates.length < 3) return json({ ok: true, ranked: candidates, reordered: false });

    const userPrompt = [
        body.city ? `City: ${body.city}` : "City: unknown",
        "",
        "Venues found nearby (already in distance order, nearest first):",
        ...candidates.map((c, i) => `${i + 1}. ${c}`),
        "",
        "Return them reordered by how likely he is to be there. JSON only.",
    ].join("\n");

    try {
        const result = await callLLM(
            { purpose: "reply", systemPrompt: SYSTEM, userPrompt, maxTokens: 900, cacheSystem: true },
            env,
        );
        const parsed = JSON.parse(stripFences(result.text)) as { ranked?: unknown };
        const ranked = Array.isArray(parsed.ranked) ? parsed.ranked.map(String) : [];

        // Trust nothing: keep only names we actually sent, drop duplicates, and
        // append anything the model forgot. A ranking that silently loses the
        // runner's real hotel would be worse than no ranking at all.
        const seen = new Set<string>();
        const safe: string[] = [];
        for (const n of ranked) {
            if (candidates.includes(n) && !seen.has(n)) { seen.add(n); safe.push(n); }
        }
        for (const c of candidates) if (!seen.has(c)) safe.push(c);

        return json({ ok: true, ranked: safe, reordered: true });
    } catch (e) {
        const desc = describeUpstreamError(e);
        await captureMessage(env, `rank-venues failed: ${desc.message}`, "warning", { route: "/rank-venues" });
        // Fail soft: the original distance order is still usable.
        return json({ ok: true, ranked: candidates, reordered: false });
    }
}

function stripFences(t: string): string {
    return t.replace(/^\s*```(?:json)?/i, "").replace(/```\s*$/, "").trim();
}

function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}
