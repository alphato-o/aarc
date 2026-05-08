import { z } from "zod";
import {
    GenerateScriptRequestSchema,
    GenerateScriptResponse,
    ScriptSchema,
} from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { callAnthropic, AnthropicError, SCRIPT_MODEL } from "../lib/anthropic";

export interface Env {
    ANTHROPIC_API_KEY: string;
}

export async function generateScriptHandler(
    request: Request,
    env: Env,
): Promise<Response> {
    if (!env.ANTHROPIC_API_KEY) {
        return json(
            { ok: false, error: "ANTHROPIC_API_KEY not configured" },
            { status: 500 },
        );
    }

    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "invalid json" }, { status: 400 });
    }

    const parsed = GenerateScriptRequestSchema.safeParse(body);
    if (!parsed.success) {
        return json(
            { ok: false, error: "invalid request", details: parsed.error.format() },
            { status: 400 },
        );
    }
    const req = parsed.data;

    const systemPrompt = systemPromptFor(req.personalityId);
    if (!systemPrompt) {
        return json(
            { ok: false, error: `unknown personality: ${req.personalityId}` },
            { status: 400 },
        );
    }

    const userPrompt = buildUserPrompt(req);

    let raw: string;
    try {
        raw = await callAnthropic({
            apiKey: env.ANTHROPIC_API_KEY,
            model: SCRIPT_MODEL,
            systemPrompt,
            userPrompt,
            maxTokens: 4096,
            cacheSystem: true,
        });
    } catch (e) {
        if (e instanceof AnthropicError) {
            return json(
                { ok: false, error: "upstream", detail: e.message },
                { status: 502 },
            );
        }
        return json(
            { ok: false, error: String(e instanceof Error ? e.message : e) },
            { status: 502 },
        );
    }

    // The model is instructed to produce JSON only. Tolerate accidental
    // code-fence wrapping; reject anything else.
    const jsonText = stripCodeFences(raw);
    let parsedScript: unknown;
    try {
        parsedScript = JSON.parse(jsonText);
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

    const validated = ScriptSchema.safeParse(parsedScript);
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

    const response: GenerateScriptResponse = {
        scriptId: crypto.randomUUID(),
        model: SCRIPT_MODEL,
        messages: validated.data,
    };
    return json({ ok: true, ...response });
}

function buildUserPrompt(
    req: z.infer<typeof GenerateScriptRequestSchema>,
): string {
    const lines: string[] = [
        `Distance: ${req.distanceKm} km`,
        `Run type: ${req.runType}`,
        `Goal: ${req.goal}`,
    ];
    if (req.targetPaceSecPerKm) {
        const m = Math.floor(req.targetPaceSecPerKm / 60);
        const s = Math.round(req.targetPaceSecPerKm % 60);
        lines.push(`Target pace: ${m}:${String(s).padStart(2, "0")} per km`);
    }
    if (req.recentRunSummary) {
        lines.push(`Recent: ${req.recentRunSummary}`);
    }
    if (req.userMemory && req.userMemory.length > 0) {
        lines.push(
            `Things known about this runner:\n- ${req.userMemory.join("\n- ")}`,
        );
    }
    lines.push("", "Generate the script now. JSON only.");
    return lines.join("\n");
}

function stripCodeFences(text: string): string {
    const trimmed = text.trim();
    if (trimmed.startsWith("```")) {
        // Remove an opening fence line and a closing fence
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
