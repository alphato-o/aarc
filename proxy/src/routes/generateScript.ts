import { z } from "zod";
import {
    GenerateScriptRequestSchema,
    GenerateScriptResponse,
    ScriptSchema,
} from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { callLLM, describeUpstreamError, LLMEnv } from "../lib/llm";

export type Env = LLMEnv;

export async function generateScriptHandler(
    request: Request,
    env: Env,
): Promise<Response> {
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
    let provider: "openrouter" | "anthropic";
    let model: string;
    try {
        const result = await callLLM(
            {
                purpose: "script",
                systemPrompt,
                userPrompt,
                maxTokens: 4096,
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

    const response: GenerateScriptResponse & { provider: string } = {
        scriptId: crypto.randomUUID(),
        model,
        messages: validated.data,
        provider,
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
