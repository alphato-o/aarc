import { z } from "zod";
import { AmbientSchema, softString, softStrings } from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { fetchAmbient, pushAmbientBlock } from "../lib/ambient";
import { callLLMJSON, LLMOutputError, describeUpstreamError, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";
import { pushBriefingBlock, BriefingEnv } from "../lib/briefing";

export type Env = LLMEnv & SentryEnv & BriefingEnv;

/// One-batch in-run roast library, generated at run start (founder idea,
/// 2026-07-10): 12-20 SHORT roasts in a single LLM call. Because the model
/// writes the whole set at once it de-duplicates against itself for free —
/// intra-batch variety beats sixteen isolated calls that each rediscover the
/// same joke. The client caches the pool and dispatches lines for filler
/// beats (quiet stretches) without a network call; live-data moments (pace,
/// HR, lyrics, milestones) still generate live. Side effect: the pool keeps
/// filler roasts flowing even through a total LLM outage.
const RoastPoolRequestSchema = z.object({
    personalityId: z.string().min(1),
    poolSize: z.number().int().min(6).max(24).optional(),
    runContext: z.object({
        planKind: z.string(),
        planDistanceKm: z.number().optional(),
        planTimeMinutes: z.number().optional(),
        runType: z.string(),
    }),
    ambient: AmbientSchema.optional(),
    personalNotes: softStrings(24, 400),
    likedLineExamples: softStrings(12, 400),
});

const RoastPoolOutputSchema = z.object({
    lines: z.array(z.string().min(4).max(320)).min(6).max(30),
});

export async function roastPoolHandler(request: Request, env: Env): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "invalid json" }, { status: 400 });
    }
    const parsed = RoastPoolRequestSchema.safeParse(body);
    if (!parsed.success) {
        return json(
            { ok: false, error: "invalid request", details: parsed.error.format() },
            { status: 400 },
        );
    }
    const req = parsed.data;
    const systemPrompt = systemPromptFor(req.personalityId, "dynamic");
    if (!systemPrompt) {
        return json({ ok: false, error: `unknown personality: ${req.personalityId}` }, { status: 400 });
    }

    const n = req.poolSize ?? 16;
    const userPrompt = await buildUserPrompt(req, n, env);

    try {
        const out = await callLLMJSON(
            // Run-start path: latency is absorbed like generate-script, so the
            // corrective retry is safe here (unlike the in-run hot path).
            { purpose: "reply", systemPrompt, userPrompt, maxTokens: 2000, cacheSystem: true },
            env,
            (raw) => {
                const obj = JSON.parse(stripCodeFences(raw));
                const v = RoastPoolOutputSchema.safeParse(obj);
                if (!v.success) {
                    throw new Error("roast pool failed schema: " + JSON.stringify(v.error.issues.slice(0, 2)));
                }
                return v.data;
            },
        );
        return json({ ok: true, lines: out.data.lines, model: out.model, provider: out.provider });
    } catch (e) {
        if (e instanceof LLMOutputError) {
            await captureMessage(env, `roast-pool rejected after retry: ${e.detail}`, "error", { route: "/roast-pool" });
            return json({ ok: false, error: "model output failed schema validation", raw: e.raw.slice(0, 400) }, { status: 502 });
        }
        const desc = describeUpstreamError(e);
        if (desc.httpStatus >= 500) {
            await captureMessage(env, `upstream LLM failure: ${desc.message}`, "error", { route: "/roast-pool", status: desc.httpStatus });
        }
        return json({ ok: false, error: "upstream", detail: desc.message }, { status: desc.httpStatus });
    }
}

async function buildUserPrompt(req: z.infer<typeof RoastPoolRequestSchema>, n: number, env: Env): Promise<string> {
    const c = req.runContext;
    const lines: string[] = [];
    lines.push(`Generate a POOL of ${n} SHORT stand-alone roast lines for this run. They will be cached and fired one at a time during quiet stretches, in random order, at unknown moments.`);
    lines.push("");
    lines.push("RUN SETUP:");
    lines.push(`- plan: ${c.planKind}${c.planDistanceKm ? ` ${c.planDistanceKm} km` : ""}${c.planTimeMinutes ? ` ${c.planTimeMinutes} min` : ""}`);
    lines.push(`- run type: ${c.runType}`);
    pushAmbientBlock(lines, req.ambient, await fetchAmbient(req.ambient ?? {}));
    await pushBriefingBlock(lines, env, "ricky", { chance: 1 });

    if (req.personalNotes && req.personalNotes.length > 0) {
        lines.push("");
        lines.push("PERSONAL TROLL FUEL — FACTS, NOT PHRASES. Use a DIFFERENT bullet (or none) per line; never quote a bullet verbatim, never use the same bullet in two lines:");
        for (const p of req.personalNotes) lines.push(`- ${p}`);
    }
    if (req.likedLineExamples && req.likedLineExamples.length > 0) {
        lines.push("");
        lines.push("LIKED LINES (CALIBRATION ONLY — DO NOT COPY). Texture references for tone/rhythm only:");
        for (const ex of req.likedLineExamples) lines.push(`- "${ex}"`);
    }

    lines.push("");
    lines.push(`POOL RULES — the whole point of batching is VARIETY, so enforce it yourself across the ${n} lines:`);
    lines.push("1. Each line: ONE sentence, at most ~150 characters, one idea, landed, out.");
    lines.push("2. Every line takes a DIFFERENT angle (different topic, target, image, and sentence shape). If two lines share a hook, a punchline structure, or a key word, rewrite one. No two lines may use the same personal-note bullet or the same ambient fact.");
    lines.push("3. TIMELESS within the run: no specific distance/elapsed references ('5k in', 'twenty minutes') — the line may fire at ANY point. Generic run-state ('still going', 'that belt') is fine.");
    lines.push("4. At most a third of the lines carry ONE audio tag ([scoffs]/[sighs]/[chuckles]/[laughs]/[snorts]/[exhales]); vary which, never the same tag twice in a row in the list; the rest land bare and deadpan.");
    lines.push("5. Stay in persona: mock-pity, deadpan, specific. No motivational-poster lines.");
    lines.push("");
    lines.push(`Return ONLY JSON: {"lines": ["...", "..."]} with exactly ${n} strings.`);
    return lines.join("\n");
}

function stripCodeFences(text: string): string {
    const trimmed = text.trim();
    if (trimmed.startsWith("```")) {
        return trimmed.replace(/^```(?:json)?\s*\n?/, "").replace(/\n?```\s*$/, "").trim();
    }
    return trimmed;
}

function json(data: unknown, init: ResponseInit = {}): Response {
    return new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });
}
