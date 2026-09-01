import {
    MusicCommentModelOutputSchema,
    MusicCommentRequest,
    MusicCommentRequestSchema,
    MusicCommentResponse,
} from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { pushPlaceBlock } from "../lib/placeBlock";
import { fetchAmbient, pushAmbientBlock } from "../lib/ambient";
import { callLLM, salvageText, describeUpstreamError, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";
import { pushBriefingBlock, BriefingEnv } from "../lib/briefing";
import { fetchVenueProfile, formatVenueProfile, VenueProfileEnv } from "../lib/venueProfile";

export type Env = LLMEnv & SentryEnv & BriefingEnv & VenueProfileEnv;

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

    const userPrompt = await buildUserPrompt(req, env);

    let raw: string;
    let provider: "openrouter" | "anthropic";
    let model: string;
    try {
        const result = await callLLM(
            {
                purpose: "reply",
                systemPrompt,
                userPrompt,
                maxTokens: 260,
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
                route: "/music-comment",
                status: desc.httpStatus,
            });
        }
        return json(
            { ok: false, error: "upstream", detail: desc.message },
            { status: desc.httpStatus },
        );
    }

    // Salvage-first (in-run hot path): play the partial text on a truncated/
    // fenced output rather than dropping the line; no retry (the extra LLM
    // round-trip causes client timeouts mid-run — proven on react-line).
    let validatedData: ReturnType<typeof MusicCommentModelOutputSchema.parse>;
    try {
        const obj = JSON.parse(stripCodeFences(raw));
        const v = MusicCommentModelOutputSchema.safeParse(obj);
        if (!v.success) throw new Error("schema validation failed");
        validatedData = v.data;
    } catch {
        const salvaged = salvageText(raw);
        if (!salvaged) {
            await captureMessage(env, `music-comment unparseable, nothing to salvage`, "error", { route: "/music-comment" });
            return json(
                { ok: false, error: "model did not return valid JSON", raw: raw.slice(0, 500) },
                { status: 502 },
            );
        }
        await captureMessage(env, `music-comment salvaged (no retry): ${raw.slice(0, 80)}`, "warning", { route: "/music-comment" });
        validatedData = { text: salvaged };
    }

    const response: MusicCommentResponse & { provider: string } = {
        text: validatedData.text,
        model,
        provider,
        pickedLine: validatedData.pickedLine,
    };
    return json({ ok: true, ...response });
}

async function buildUserPrompt(req: MusicCommentRequest, env: Env): Promise<string> {
    const lines: string[] = [];

    const hasFull = !!req.fullLyrics && req.fullLyrics.length > 0;

    if (hasFull) {
        lines.push("FULL LYRICS. The whole song. YOU pick what to roast:");
        if (req.lyricLanguage) {
            lines.push(`(language: ${req.lyricLanguage === "zh" ? "Chinese" : "English"})`);
        }
        for (const l of req.fullLyrics!) {
            lines.push(`- "${l}"`);
        }
        lines.push("");
        lines.push(
            "FIND THE PUNCHLINE. Read the whole thing and pick the ONE line a human " +
            "would actually react to: the line that is absurd, overwrought, filthy, " +
            "unintentionally funny, wildly self-important, or just the bit everyone " +
            "quotes. That line is your target. It is usually NOT the chorus, and it " +
            "is usually not the line that happens to be playing right now.",
        );
        if (req.currentLyric) {
            lines.push("");
            lines.push(`For timing only, the line playing at this second is: "${req.currentLyric}". Use it ONLY if it happens to be the best target anyway. Do not force it.`);
        }
    } else if (req.currentLyric) {
        // No lyric body available (unsynced miss, or an older client): fall
        // back to the single-line behaviour rather than going silent.
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
    pushPlaceBlock(lines, c.place);
    const vProfileRaw = await fetchVenueProfile(env, c.ambient?.venueConfirmed ? c.ambient?.venue : undefined);
    const vProfile = vProfileRaw && c.ambient?.venue ? formatVenueProfile(c.ambient!.venue!, vProfileRaw) : null;
    pushAmbientBlock(lines, c.ambient, await fetchAmbient(c.ambient ?? {}), vProfile);
    await pushBriefingBlock(lines, env, "ricky");

    if (req.personalNotes && req.personalNotes.length > 0) {
        lines.push("");
        lines.push("PERSONAL TROLL FUEL — FACTS, NOT PHRASES. Occasionally fuse one of these with the lyric riff, but ALWAYS re-phrase. Never quote a bullet verbatim:");
        for (const p of req.personalNotes) {
            lines.push(`- ${p}`);
        }
    }

    if (req.likedLineExamples && req.likedLineExamples.length > 0) {
        lines.push("");
        lines.push("LIKED LINES (CALIBRATION ONLY — DO NOT COPY). Heart-tagged from past runs. Texture references only — never re-use a phrase or punchline from this list:");
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
    }

    lines.push("");
    if (hasFull) {
        lines.push(
            "Pick the punchline, then generate ONE DJ commentary line trolling THAT line. " +
            "Make it obvious which line you went for: quote or unmistakably reference it. " +
            "If a line you already used is listed under RECENTLY SPOKEN, pick the next " +
            "best target instead of repeating yourself. BREVITY IS BITE: 1-2 sentences, " +
            "at most ~260 characters. One joke, landed, out. " +
            'JSON only: {"text": "...", "pickedLine": "the exact lyric you targeted"}',
        );
    } else if (req.currentLyric) {
        lines.push("Generate ONE DJ commentary line reacting to the lyric line above. BREVITY IS BITE: 1-2 sentences, at most ~260 characters — one joke, landed, out. JSON only.");
    } else {
        lines.push("Generate ONE DJ commentary line about the current track. BREVITY IS BITE: 1-2 sentences, at most ~260 characters — one joke, landed, out. JSON only.");
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
