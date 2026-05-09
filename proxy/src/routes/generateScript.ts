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
    const lines: string[] = [];

    switch (req.planKind) {
        case "distance":
            lines.push(
                `PLAN: distance run, ${req.distanceKm} km. The runner has a fixed target distance; the script must include the distance-mode required messages (per-km loop, halfway, near_finish with remainingMeters: 100, finish).`,
            );
            break;
        case "time":
            lines.push(
                `PLAN: timed run, ${req.timeMinutes} minutes. The runner is running for a fixed time; the script must include the time-mode required messages (a recurring time.everySeconds loop, halfway, near_finish with remainingSeconds: 60, finish). The runner may or may not cross km marks; you can include distance.everyMeters: 1000 if you like, but it is optional.`,
            );
            break;
        case "open":
            lines.push(
                `PLAN: open run, no distance or time target. The runner stops when they want. The script must NOT include halfway, finish, or near_finish triggers — there is no defined end. Use distance.everyMeters: 1000 for the per-km loop and scattered time.atSeconds at varied N values for surprise roasts.`,
            );
            break;
    }

    lines.push(`Run type: ${req.runType}`);
    lines.push(`Goal: ${req.goal}`);
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
