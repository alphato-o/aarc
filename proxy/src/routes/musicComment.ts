import {
    MusicCommentModelOutputSchema,
    MusicCommentRequest,
    MusicCommentRequestSchema,
    MusicCommentResponse,
} from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { callLLM, describeUpstreamError, LLMEnv } from "../lib/llm";

export type Env = LLMEnv;

export async function musicCommentHandler(
    request: Request,
    env: Env,
): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "invalid json" }, { status: 400 });
    }

    const parsed = MusicCommentRequestSchema.safeParse(body);
    if (!parsed.success) {
        return json(
            { ok: false, error: "invalid request", details: parsed.error.format() },
            { status: 400 },
        );
    }
    const req = parsed.data;

    const systemPrompt = systemPromptFor(req.personalityId, "music");
    if (!systemPrompt) {
        return json(
            { ok: false, error: `unknown personality: ${req.personalityId}` },
            { status: 400 },
        );
    }

    const userPrompt = buildUserPrompt(req);

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

    const validated = MusicCommentModelOutputSchema.safeParse(parsedObj);
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

    const response: MusicCommentResponse & { provider: string } = {
        text: validated.data.text,
        model,
        provider,
    };
    return json({ ok: true, ...response });
}

function buildUserPrompt(req: MusicCommentRequest): string {
    const lines: string[] = [];

    if (req.currentLyric) {
        lines.push("LYRIC LINE BEING SUNG RIGHT NOW (your primary subject — roast THIS line):");
        lines.push(`"${req.currentLyric}"`);
        if (req.lyricLanguage) {
            lines.push(`(language: ${req.lyricLanguage === "zh" ? "Chinese" : "English"})`);
        }
        if (req.lyricContext && req.lyricContext.length > 0) {
            lines.push("");
            lines.push("Surrounding lines (for flow only — do not riff on these unless they help the joke about the current line):");
            for (const ctx of req.lyricContext) {
                lines.push(`- "${ctx}"`);
            }
        }
    }

    if (req.track && (req.track.title || req.track.artist)) {
        lines.push("");
        lines.push("TRACK (supporting context only — don't lead with this):");
        if (req.track.title) lines.push(`- title: ${req.track.title}`);
        if (req.track.artist) lines.push(`- artist: ${req.track.artist}`);
        if (req.track.album) lines.push(`- album: ${req.track.album}`);
        if (req.track.isPlaying === false) {
            lines.push("- note: track is paused right now");
        }
    } else if (req.unknownAudio && !req.currentLyric) {
        lines.push("AUDIO STATE: something is playing but we don't have track metadata or a lyric line.");
    } else if (!req.currentLyric && !req.track) {
        lines.push("AUDIO STATE: nothing detected playing.");
    }

    const c = req.runContext;
    lines.push("");
    lines.push("RUN STATE:");
    lines.push(`- elapsed: ${formatSeconds(c.elapsedSeconds)}`);
    lines.push(`- distance: ${(c.distanceMeters / 1000).toFixed(2)} km`);
    if (c.currentHR !== undefined) {
        lines.push(`- HR: ${Math.round(c.currentHR)} bpm`);
    }
    if (c.currentPaceSecPerKm !== undefined) {
        lines.push(`- pace: ${formatPace(c.currentPaceSecPerKm)}/km`);
    }
    lines.push(`- plan: ${c.planKind}`);
    lines.push(`- run type: ${c.runType}`);

    if (req.recentDispatched && req.recentDispatched.length > 0) {
        lines.push("");
        lines.push("RECENTLY SPOKEN LINES (do NOT repeat ideas or phrasing):");
        for (const r of req.recentDispatched) {
            lines.push(`- ${r}`);
        }
    }

    lines.push("");
    if (req.currentLyric) {
        lines.push("Generate ONE DJ commentary line reacting to the lyric line above. JSON only.");
    } else {
        lines.push("Generate ONE DJ commentary line about the current track. JSON only.");
    }
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
