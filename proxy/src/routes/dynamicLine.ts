import {
    DynamicLineModelOutputSchema,
    DynamicLineRequest,
    DynamicLineRequestSchema,
    DynamicLineResponse,
} from "../schemas";
import { systemPromptFor, runPhaseBlock } from "../lib/personalities";
import { pushPlaceBlock } from "../lib/placeBlock";
import { fetchAmbient, pushAmbientBlock } from "../lib/ambient";
import { callLLM, salvageText, describeUpstreamError, LLMEnv } from "../lib/llm";
import { buildRepetitionBan } from "../lib/repetition";
import { captureMessage, SentryEnv } from "../lib/sentry";

export type Env = LLMEnv & SentryEnv;

export async function dynamicLineHandler(
    request: Request,
    env: Env,
): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "invalid json" }, { status: 400 });
    }

    const parsed = DynamicLineRequestSchema.safeParse(body);
    if (!parsed.success) {
        return json(
            { ok: false, error: "invalid request", details: parsed.error.format() },
            { status: 400 },
        );
    }
    const req = parsed.data;

    const systemPrompt = systemPromptFor(req.personalityId, "dynamic");
    if (!systemPrompt) {
        return json(
            { ok: false, error: `unknown personality: ${req.personalityId}` },
            { status: 400 },
        );
    }

    const userPrompt = await buildUserPrompt(req);

    let raw: string;
    let provider: "openrouter" | "anthropic";
    let model: string;
    try {
        const result = await callLLM(
            {
                purpose: "reply",
                systemPrompt,
                userPrompt,
                maxTokens: 400,
                cacheSystem: true,
            },
            env,
        );
        raw = result.text;
        provider = result.provider;
        model = result.model;
    } catch (e) {
        const desc = describeUpstreamError(e);
        if (desc.httpStatus >= 500) {
            await captureMessage(env, `upstream LLM failure: ${desc.message}`, "error", {
                route: "/dynamic-line",
                status: desc.httpStatus,
            });
        }
        return json(
            { ok: false, error: "upstream", detail: desc.message },
            { status: desc.httpStatus },
        );
    }

    // Salvage-first (in-run hot path): if the output won't parse — almost always
    // a ```json fence overrunning the token budget and truncating the JSON —
    // play the partial text rather than drop the line. No corrective retry:
    // react-line proved the extra LLM round-trip pushes in-run requests past the
    // client timeout. A near-complete salvaged line beats a slow retry or silence.
    let validatedData: ReturnType<typeof DynamicLineModelOutputSchema.parse>;
    try {
        const obj = JSON.parse(stripCodeFences(raw));
        const v = DynamicLineModelOutputSchema.safeParse(obj);
        if (!v.success) throw new Error("schema validation failed");
        validatedData = v.data;
    } catch {
        const salvaged = salvageText(raw);
        if (!salvaged) {
            await captureMessage(env, `dynamic-line unparseable, nothing to salvage`, "error", { route: "/dynamic-line" });
            return json(
                { ok: false, error: "model did not return valid JSON", raw: raw.slice(0, 500) },
                { status: 502 },
            );
        }
        await captureMessage(env, `dynamic-line salvaged (no retry): ${raw.slice(0, 80)}`, "warning", { route: "/dynamic-line" });
        validatedData = { text: salvaged };
    }

    // Anti-tic guard (mirror of Jessica's): Ricky's reactive lines — especially
    // quiet_stretch — kept opening "X minutes in and [here's a thought / I've
    // been thinking]…". The prose ban is ignored, so enforce it: if the draft
    // trips the tic, fire ONE corrective rewrite.
    let finalText = validatedData.text;
    if (req.personalityId === "roast_coach" && tripsRickyTic(finalText)) {
        finalText = await rewriteRickyOffTic(finalText, systemPrompt, userPrompt, env) ?? finalText;
    }

    const response: DynamicLineResponse & { provider: string } = {
        text: finalText,
        model,
        provider,
    };
    return json({ ok: true, ...response });
}

/// Ricky's reactive tic: announcing elapsed time ("X minutes/k in…") or a
/// stalling opener ("here's a thought", "I've been thinking/realised", "been
/// quiet…"). Strip tags first.
function tripsRickyTic(text: string): boolean {
    const s = text.replace(/\[[^\]]*\]/g, "").trim();
    if (/^\S+\s+(minutes?|mins?|k|kilometres?|km)\s+(in|on)\b/i.test(s)) return true;
    if (/^(so\s+)?(here'?s a thought|i'?ve been thinking|i'?ve (just )?realised|i'?ve realized|been (quiet|silent|dead quiet)|right(,| then)|ok(ay)?,? so)\b/i.test(s)) return true;
    return false;
}

async function rewriteRickyOffTic(
    draft: string, systemPrompt: string, userPrompt: string, env: Env,
): Promise<string | null> {
    const correction = `${userPrompt}

YOUR DRAFT WAS: "${draft}"
That opened with a BANNED tic — either announcing how long it's been ("X minutes in…") or a stalling frame ("here's a thought", "I've been thinking", "been quiet"…). Rewrite it COMPLETELY: open STRAIGHT on the image/joke, a genuinely different shape, and never reference the elapsed time. JSON only.`;
    try {
        const result = await callLLM(
            { purpose: "reply", systemPrompt, userPrompt: correction, maxTokens: 400, cacheSystem: true },
            env,
        );
        const parsed = JSON.parse(stripCodeFences(result.text));
        const ok = DynamicLineModelOutputSchema.safeParse(parsed);
        return ok.success ? ok.data.text : null;
    } catch {
        return null;
    }
}

async function buildUserPrompt(req: DynamicLineRequest): Promise<string> {
    const c = req.runContext;
    const lines: string[] = [];

    lines.push(`EVENT: ${req.trigger}`);
    lines.push("");
    lines.push("RUN STATE:");
    lines.push(`- elapsed: ${formatSeconds(c.elapsedSeconds)} (${Math.round(c.elapsedSeconds)}s)`);
    lines.push(`- distance: ${(c.distanceMeters / 1000).toFixed(2)} km`);
    if (c.currentHR !== undefined) {
        const drift = c.avgHR !== undefined
            ? ` (avg so far: ${Math.round(c.avgHR)})`
            : "";
        lines.push(`- HR: ${Math.round(c.currentHR)} bpm${drift}`);
    }
    if (c.currentPaceSecPerKm !== undefined) {
        const drift = c.avgPaceSecPerKm !== undefined
            ? ` (avg so far: ${formatPace(c.avgPaceSecPerKm)}/km)`
            : "";
        lines.push(`- current pace: ${formatPace(c.currentPaceSecPerKm)}/km${drift}`);
    }
    switch (c.planKind) {
        case "distance":
            if (c.planDistanceKm) {
                const remainingKm = Math.max(0, c.planDistanceKm - c.distanceMeters / 1000);
                lines.push(`- plan: ${c.planDistanceKm} km (${remainingKm.toFixed(2)} km remaining)`);
            }
            break;
        case "time":
            if (c.planTimeMinutes) {
                const remainingS = Math.max(0, c.planTimeMinutes * 60 - c.elapsedSeconds);
                lines.push(`- plan: ${c.planTimeMinutes} min (${formatSeconds(remainingS)} remaining)`);
            }
            break;
        case "open":
            lines.push(`- plan: open (runner stops when they want)`);
            break;
    }
    lines.push(`- run type: ${c.runType}`);
    // Emotional arc: pure contempt early → grudging respect late.
    {
        let progress = c.progressFraction ?? 0;
        if (progress <= 0) {
            if (c.planKind === "distance" && c.planDistanceKm) progress = (c.distanceMeters / 1000) / c.planDistanceKm;
            else if (c.planKind === "time" && c.planTimeMinutes) progress = c.elapsedSeconds / (c.planTimeMinutes * 60);
            else progress = c.elapsedSeconds / 2400;
        }
        lines.push("");
        lines.push(runPhaseBlock(Math.min(0.999, Math.max(0, progress)), "ricky"));
    }
    if (c.stationarySeconds !== undefined && c.stationarySeconds > 0) {
        lines.push(`- stationary for: ${Math.round(c.stationarySeconds)}s (they were running and have now STOPPED — quote the seconds, never a distance)`);
    }
    pushPlaceBlock(lines, c.place);
    pushAmbientBlock(lines, c.ambient, await fetchAmbient(c.ambient ?? {}));

    if (req.customNote && req.customNote.trim().length > 0) {
        lines.push("");
        lines.push(`CONTEXT: ${req.customNote.trim()}`);
    }

    if (req.personalNotes && req.personalNotes.length > 0) {
        lines.push("");
        lines.push("PERSONAL TROLL FUEL — FACTS, NOT PHRASES. Things the runner has told us about themselves. Use the FACTS as material; invent a NEW angle each line. NEVER copy a bullet verbatim — change the image, the metaphor, the vocabulary. The bullet 'X has 10 users' should become a fresh joke ('X — fewer fans than a Croatian bocce league') not a regurgitation:");
        for (const p of req.personalNotes) {
            lines.push(`- ${p}`);
        }
    }

    if (req.likedLineExamples && req.likedLineExamples.length > 0) {
        lines.push("");
        lines.push("LIKED LINES (CALIBRATION ONLY — DO NOT COPY). Heart-tagged by the runner in past runs. Use them as TEXTURE only: length, rhythm, swagger, specificity. You are FORBIDDEN from reusing any phrase, image, or punchline from this list. If a draft echoes one, rewrite from scratch:");
        for (const ex of req.likedLineExamples) {
            lines.push(`- "${ex}"`);
        }
    }

    if (req.recentDispatched && req.recentDispatched.length > 0) {
        lines.push("");
        lines.push("RECENTLY SPOKEN LINES (do NOT repeat ideas or phrasing):");
        for (const r of req.recentDispatched) {
            lines.push(`- ${r}`);
        }
        const ban = buildRepetitionBan(req.recentDispatched);
        if (ban) {
            lines.push("");
            lines.push(ban);
        }
    }

    lines.push("");
    lines.push("Generate ONE reactive line for THIS event right now. JSON only.");
    return lines.join("\n");
}

function formatSeconds(seconds: number): string {
    const s = Math.max(0, Math.round(seconds));
    const m = Math.floor(s / 60);
    const r = s % 60;
    return `${m}:${r.toString().padStart(2, "0")}`;
}

function formatPace(secPerKm: number): string {
    const s = Math.max(0, Math.round(secPerKm));
    const m = Math.floor(s / 60);
    const r = s % 60;
    return `${m}:${r.toString().padStart(2, "0")}`;
}

function stripCodeFences(text: string): string {
    const trimmed = text.trim();
    if (trimmed.startsWith("```")) {
        const withoutOpen = trimmed.replace(/^```(?:json)?\s*\n?/, "");
        return withoutOpen.replace(/\n?```\s*$/, "").trim();
    }
    return trimmed;
}

function json(data: unknown, init: ResponseInit = {}): Response {
    return new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });
}
