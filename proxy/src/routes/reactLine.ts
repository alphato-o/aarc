import {
    ReactLineModelOutputSchema,
    ReactLineRequest,
    ReactLineRequestSchema,
    ReactLineResponse,
} from "../schemas";
import { reactModeFor, systemPromptFor, JessicaLengthMode } from "../lib/personalities";
import { callLLM, describeUpstreamError, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";

export type Env = LLMEnv & SentryEnv;

// Token ceiling per Jessica length mode. Roughly 4 chars/token, with slack so
// the model can finish a sentence rather than getting truncated mid-word.
const MAX_TOKENS_BY_LENGTH: Record<JessicaLengthMode, number> = {
    quip: 180,
    medium: 360,
    indulgent: 700,
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

    const userPrompt = buildUserPrompt(req);

    // Cap output by length mode so a quip can't run long and an indulgent
    // passage has room to breathe. Char targets: quip <=140, medium ~220-380,
    // indulgent ~450-650.
    const maxTokens = MAX_TOKENS_BY_LENGTH[lengthMode];

    let raw: string;
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
        raw = result.text;
        provider = result.provider;
        model = result.model;
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

    const jsonText = stripCodeFences(raw);
    let parsedObj: unknown;
    try {
        parsedObj = JSON.parse(jsonText);
    } catch {
        return json(
            {
                ok: false,
                error: "model did not return valid JSON",
                raw: raw.slice(0, 500),
            },
            { status: 502 },
        );
    }

    const validated = ReactLineModelOutputSchema.safeParse(parsedObj);
    if (!validated.success) {
        return json(
            {
                ok: false,
                error: "model output failed schema validation",
                details: validated.error.format(),
                raw: raw.slice(0, 500),
            },
            { status: 502 },
        );
    }

    const response: ReactLineResponse & { provider: string } = {
        text: validated.data.text,
        model,
        provider,
    };
    return json({ ok: true, ...response });
}

function buildUserPrompt(req: ReactLineRequest): string {
    const c = req.runContext;
    const lines: string[] = [];

    lines.push(`RICKY JUST SAID: "${req.partnerLine.trim()}"`);
    if (req.partnerSource) {
        lines.push(`(moment: ${req.partnerSource})`);
    }
    lines.push("");
    lines.push("React to that — build on it, then make it yours.");
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
        lines.push("RECENTLY SPOKEN LINES (both voices — do NOT repeat ideas or phrasing):");
        for (const r of req.recentDispatched) {
            lines.push(`- ${r}`);
        }
    }

    lines.push("");
    lines.push("Now give your ONE line reacting to Ricky. JSON only.");
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
