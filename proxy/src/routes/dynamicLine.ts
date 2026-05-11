import {
    DynamicLineModelOutputSchema,
    DynamicLineRequest,
    DynamicLineRequestSchema,
    DynamicLineResponse,
} from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { callLLM, describeUpstreamError, LLMEnv } from "../lib/llm";

export type Env = LLMEnv;

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

    const validated = DynamicLineModelOutputSchema.safeParse(parsedObj);
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

    const response: DynamicLineResponse & { provider: string } = {
        text: validated.data.text,
        model,
        provider,
    };
    return json({ ok: true, ...response });
}

function buildUserPrompt(req: DynamicLineRequest): string {
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

    if (req.customNote && req.customNote.trim().length > 0) {
        lines.push("");
        lines.push(`CONTEXT: ${req.customNote.trim()}`);
    }

    if (req.recentDispatched && req.recentDispatched.length > 0) {
        lines.push("");
        lines.push("RECENTLY SPOKEN LINES (do NOT repeat ideas or phrasing):");
        for (const r of req.recentDispatched) {
            lines.push(`- ${r}`);
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
