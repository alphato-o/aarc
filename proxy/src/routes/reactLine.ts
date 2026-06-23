import {
    ReactLineModelOutputSchema,
    ReactLineRequest,
    ReactLineRequestSchema,
    ReactLineResponse,
} from "../schemas";
import { reactModeFor, systemPromptFor, runPhaseBlock, JessicaLengthMode } from "../lib/personalities";
import { deckBlock, DeckMode } from "../lib/jessicaDeck";
import { pushPlaceBlock } from "../lib/placeBlock";
import { fetchAmbient, pushAmbientBlock } from "../lib/ambient";
import { callLLM, salvageText, describeUpstreamError, LLMEnv } from "../lib/llm";
import { buildRepetitionBan } from "../lib/repetition";
import { captureMessage, SentryEnv } from "../lib/sentry";

export type Env = LLMEnv & SentryEnv;

// Token ceiling per Jessica length mode — a REAL mechanical cap, not just a
// hint. At ~4 chars/token: quip ≤140c, medium ~220-380c, indulgent ~450-650c,
// summary ~160-280c. The old ceilings (180/360/700) gave a "quip" ~720 chars
// of room, so the model ignored the soft length instruction and every line
// came out a 500-char indulgent monologue (logged quip → 414-557c). These
// keep just enough slack to finish a sentence, no more.
const MAX_TOKENS_BY_LENGTH: Record<JessicaLengthMode, number> = {
    quip: 55,
    medium: 120,
    indulgent: 220,
    summary: 95,
};

// A blunt char budget restated in the USER prompt (the last thing the model
// reads, and the strongest signal) so the length actually binds.
const CHAR_BUDGET_BY_LENGTH: Record<JessicaLengthMode, string> = {
    quip: "HARD LENGTH LIMIT: ONE sentence, at most ~140 characters. A single sharp strike — no scene, no build, no second sentence. If you're describing an act in detail, you've already overrun. Stop after one line.",
    medium: "HARD LENGTH LIMIT: 2-3 sentences, at most ~380 characters. One vivid idea, landed and out — not a paragraph, not a full fantasy.",
    indulgent: "LENGTH: a flowing passage, ~450-650 characters. This is the rare long one — build it, but still land and stop; do not run past ~650.",
    summary: "HARD LENGTH LIMIT: 2 sentences, at most ~280 characters. A short warm sign-off, not a fantasy.",
};

/// Second-voice reaction. Jessica reacts to a line the primary coach (Ricky)
/// just spoke. Additive — the primary voice's generation is untouched; this
/// is conditioned on his line so the two read as a continuous two-hander.
export async function reactLineHandler(
    request: Request,
    env: Env,
): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "invalid json" }, { status: 400 });
    }

    const parsed = ReactLineRequestSchema.safeParse(body);
    if (!parsed.success) {
        return json(
            { ok: false, error: "invalid request", details: parsed.error.format() },
            { status: 400 },
        );
    }
    const req = parsed.data;

    // Length drives both the system-prompt profile and the token ceiling.
    // Absent => "medium" (the established default).
    const lengthMode: JessicaLengthMode = req.lengthMode ?? "medium";

    const systemPrompt = systemPromptFor(req.personalityId, reactModeFor(lengthMode));
    if (!systemPrompt) {
        return json(
            { ok: false, error: `unknown personality: ${req.personalityId}` },
            { status: 400 },
        );
    }

    const userPrompt = await buildUserPrompt(req, lengthMode);

    // Cap output by length mode so a quip can't run long and an indulgent
    // passage has room to breathe. Char targets: quip <=140, medium ~220-380,
    // indulgent ~450-650.
    const maxTokens = MAX_TOKENS_BY_LENGTH[lengthMode];

    // SALVAGE-FIRST (in-run hot path). react-line fires DURING the run on a
    // tight client timeout. A corrective retry (a 2nd LLM round-trip) was the
    // first fix for the ```json-fence truncation 502s, but its added latency
    // pushed the request past the client timeout — 3 timeout-DROPS in the field.
    // So here we do ONE call and, if it won't parse, SALVAGE the partial text
    // immediately (no second call). The truncation is almost always near the
    // end, so the salvaged line is near-complete — and a near-complete line
    // delivered fast beats both a slow retry and a silent drop. (The slower
    // retry path still lives in callLLMJSON for run-start endpoints like
    // /generate-script, where the timeout budget is loose.)
    let validatedData: ReturnType<typeof ReactLineModelOutputSchema.parse>;
    let provider: "openrouter" | "anthropic";
    let model: string;
    try {
        const result = await callLLM(
            {
                purpose: "reply",
                systemPrompt,
                userPrompt,
                // Set by lengthMode above — quip is fast and light, indulgent
                // gets the full immersive-passage budget.
                maxTokens,
                cacheSystem: true,
            },
            env,
        );
        provider = result.provider;
        model = result.model;
        try {
            const obj = JSON.parse(stripCodeFences(result.text));
            const v = ReactLineModelOutputSchema.safeParse(obj);
            if (!v.success) throw new Error("schema validation failed");
            validatedData = v.data;
        } catch {
            const salvaged = salvageText(result.text);
            if (salvaged) {
                await captureMessage(env, `react-line salvaged (no retry): ${result.text.slice(0, 80)}`, "warning", {
                    route: "/react-line",
                });
                validatedData = { text: salvaged };
                model = `${model} (salvaged)`;
            } else {
                await captureMessage(env, `react-line unparseable, nothing to salvage`, "error", {
                    route: "/react-line",
                });
                return json(
                    { ok: false, error: "model did not return valid JSON", raw: result.text.slice(0, 500) },
                    { status: 502 },
                );
            }
        }
    } catch (e) {
        const desc = describeUpstreamError(e);
        if (desc.httpStatus >= 500) {
            await captureMessage(env, `upstream LLM failure: ${desc.message}`, "error", {
                route: "/react-line",
                status: desc.httpStatus,
            });
        }
        return json(
            { ok: false, error: "upstream", detail: desc.message },
            { status: desc.httpStatus },
        );
    }

    // Anti-tic guard: the persona BANS the "<hook> — darling, …" opener and
    // opening on "darling", but the model ignores the prose ban (measured at
    // ~67% / ~63% in the feedback-sim). So enforce it deterministically — if
    // the draft trips the template, fire ONE corrective rewrite. Bounded cost
    // (only offending lines), and it forces her OFF the lazy default rather
    // than relying on her to obey a buried rule.
    let finalText = validatedData.text;
    if (req.personalityId === "jessica" && tripsOpenerTic(finalText)) {
        finalText = await rewriteOffTic(finalText, systemPrompt, userPrompt, maxTokens, env) ?? finalText;
    }

    const response: ReactLineResponse & { provider: string } = {
        text: finalText,
        model,
        provider,
    };
    return json({ ok: true, ...response });
}

/// The lazy template: a short hook phrase then an em/en/double dash early in
/// the line, OR opening on "darling". Strip tags first so "[giggles] darling"
/// is caught. Mirrors the feedback-sim analyzer's detector.
function tripsOpenerTic(text: string): boolean {
    const s = text.replace(/\[[^\]]*\]/g, "").trim();
    if (/^darling\b/i.test(s)) return true;
    const m = s.match(/[—–]{1,2}|\s--\s|\.\.\.|…/);
    return !!m && (m.index ?? 99) <= 55;
}

/// One corrective rewrite that names the offence and demands a different shape.
async function rewriteOffTic(
    draft: string, systemPrompt: string, userPrompt: string, maxTokens: number, env: Env,
): Promise<string | null> {
    const correction = `${userPrompt}

YOUR DRAFT WAS: "${draft}"
That draft used the BANNED opener: a hook word/phrase then a dash, or it opened on "darling". Rewrite it COMPLETELY — same meaning is fine, but a DIFFERENT opening shape (a flat verdict, a question, a command, a number thrown back, pure filth with no preamble, or plain boredom) and do NOT open with the hook word or with "darling". Keep within the same length limit. JSON only.`;
    try {
        const result = await callLLM(
            { purpose: "reply", systemPrompt, userPrompt: correction, maxTokens, cacheSystem: true },
            env,
        );
        const parsed = JSON.parse(stripCodeFences(result.text));
        const ok = ReactLineModelOutputSchema.safeParse(parsed);
        return ok.success ? ok.data.text : null;
    } catch {
        return null;
    }
}

async function buildUserPrompt(req: ReactLineRequest, lengthMode: JessicaLengthMode): Promise<string> {
    const c = req.runContext;
    const lines: string[] = [];

    const isMilestone = !!req.partnerSource && req.partnerSource.startsWith("milestone:");
    if (isMilestone) {
        lines.push(`MILESTONE: ${req.partnerLine.trim()}`);
        lines.push(`(moment: ${req.partnerSource})`);
        lines.push("");
        lines.push("THIS KILOMETRE IS YOURS — Ricky's sitting it out, you mark it. Reward him for crossing it: make him feel it in his body, vivid and immersive, the fuel that drags him to the next marker. Don't just restate the number — react to the ACHIEVEMENT and exactly what it earns him.");
    } else {
        lines.push(`RICKY JUST SAID: "${req.partnerLine.trim()}"`);
        if (req.partnerSource) {
            lines.push(`(moment: ${req.partnerSource})`);
        }
        lines.push("");
        lines.push("Pick ONE hook from that line — a word, an image, his claim, his punchline, or the topic — and react to THAT: agree and pile on, undercut him, or twist it to your angle. Don't restate his sentence and don't speak in isolation. Then make it yours.");
    }
    lines.push("");
    lines.push("RUN STATE:");
    lines.push(`- elapsed: ${formatSeconds(c.elapsedSeconds)} (${Math.round(c.elapsedSeconds)}s)`);
    lines.push(`- distance: ${(c.distanceMeters / 1000).toFixed(2)} km`);
    if (c.currentHR !== undefined) {
        lines.push(`- HR: ${Math.round(c.currentHR)} bpm`);
    }
    if (c.currentPaceSecPerKm !== undefined) {
        lines.push(`- current pace: ${formatPace(c.currentPaceSecPerKm)}/km`);
    }
    lines.push(`- plan: ${c.planKind}`);
    lines.push(`- run type: ${c.runType}`);
    // Emotional arc: cold early → "rewardy" late.
    {
        const p = c.progressFraction ?? Math.min(0.999, c.elapsedSeconds / 2400);
        lines.push("");
        lines.push(runPhaseBlock(Math.min(0.999, Math.max(0, p)), "jessica"));
    }
    pushPlaceBlock(lines, c.place);
    pushAmbientBlock(lines, c.ambient, await fetchAmbient(c.ambient ?? {}));

    if (req.personalNotes && req.personalNotes.length > 0) {
        lines.push("");
        lines.push("PERSONAL TROLL FUEL — FACTS about the runner, NOT phrases. Optional spice for you; lead with your OWN angle (his money, your indifference, the rejection). Never copy a bullet verbatim — invent a fresh image:");
        for (const p of req.personalNotes) {
            lines.push(`- ${p}`);
        }
    }

    if (req.likedLineExamples && req.likedLineExamples.length > 0) {
        lines.push("");
        lines.push("LIKED LINES (CALIBRATION ONLY — DO NOT COPY). Texture references for length/rhythm/swagger only. Forbidden to reuse any phrase, image, or punchline:");
        for (const ex of req.likedLineExamples) {
            lines.push(`- "${ex}"`);
        }
    }

    if (req.recentDispatched && req.recentDispatched.length > 0) {
        lines.push("");
        lines.push("ALREADY SAID THIS RUN (both voices, your own lines included — these JUST played). Do NOT echo them: change your OPENER, your central IMAGE, your KEY WORDS, and your sentence shape. If a recent line leaned on a word, act or idea, deliberately reach for a DIFFERENT one. Saying the same thing the same way twice reads mechanical and bored — variety is the whole job:");
        for (const r of req.recentDispatched) {
            lines.push(`- ${r}`);
        }
        // Deterministic over-use ban: pull the words/phrases actually being
        // repeated across recent lines and forbid them outright. The prose plea
        // above gets ignored; this names the offenders.
        const ban = buildRepetitionBan(req.recentDispatched);
        if (ban) {
            lines.push("");
            lines.push(ban);
        }
    }

    // Deal her a fresh, non-repeating hand of content cards to improvise off
    // (Jessica only) — the "play, don't recite" anti-repeat engine.
    if (req.personalityId === "jessica") {
        lines.push("");
        lines.push(deckBlock(lengthMode as DeckMode, req.runSeed ?? 0, req.deckOrdinal ?? 0));
    }

    lines.push("");
    lines.push(CHAR_BUDGET_BY_LENGTH[lengthMode]);
    lines.push(isMilestone
        ? "Now give your ONE milestone line — mark his kilometre, fresh and vivid, nothing like the lines above, WITHIN the length limit. JSON only."
        : "Now give your ONE line — a reply that latches onto your chosen hook from Ricky's line, fresh and nothing like the lines above, WITHIN the length limit. JSON only.");
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
