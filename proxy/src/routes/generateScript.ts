import { z } from "zod";
import {
    GenerateScriptRequestSchema,
    GenerateScriptResponse,
    ScriptSchema,
} from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { courseById, courseFor, courseScriptBlock } from "../lib/course";
import { callLLMJSON, LLMOutputError, describeUpstreamError, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";
import { pushBriefingBlock, BriefingEnv } from "../lib/briefing";

export type Env = LLMEnv & SentryEnv & BriefingEnv;

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

    const userPrompt = await buildUserPrompt(req, env);
    // The race pack carries ~30 one-shot course lines on top of the usual
    // skeleton; the normal budget would truncate the JSON mid-array.
    const maxTokens = racePackCourse(req) ? 16000 : 4096;

    let validated: { data: ReturnType<typeof ScriptSchema.parse> };
    let provider: "openrouter" | "anthropic";
    let model: string;
    try {
        const out = await callLLMJSON(
            { purpose: "script", systemPrompt, userPrompt, maxTokens, cacheSystem: true },
            env,
            (raw) => {
                const parsed = JSON.parse(stripCodeFences(raw));
                const v = ScriptSchema.safeParse(parsed);
                if (!v.success) {
                    throw new Error(
                        "output is not a valid run script: " +
                            JSON.stringify(v.error.issues.slice(0, 2)),
                    );
                }
                return v.data;
            },
        );
        validated = { data: out.data };
        provider = out.provider;
        model = out.model;
    } catch (e) {
        if (e instanceof LLMOutputError) {
            await captureMessage(env, `script output rejected after retry: ${e.detail}`, "error", {
                route: "/generate-script",
            });
            return json(
                { ok: false, error: "model output failed schema validation after retry", raw: e.raw.slice(0, 500) },
                { status: 502 },
            );
        }
        const desc = describeUpstreamError(e);
        if (desc.httpStatus >= 500) {
            await captureMessage(env, `upstream LLM failure: ${desc.message}`, "error", {
                route: "/generate-script",
                status: desc.httpStatus,
            });
        }
        return json({ ok: false, error: "upstream", detail: desc.message }, { status: desc.httpStatus });
    }

    // Race pack: a one-shot on a round kilometre would stack on the kilometre
    // call, which Home Base owns. Nudge any such line to +350 m, keeping order.
    const messages = racePackCourse(req) ? nudgeOffKilometres(validated.data) : validated.data;
    const response: GenerateScriptResponse & { provider: string } = {
        scriptId: crypto.randomUUID(),
        model,
        messages,
        provider,
    };
    return json({ ok: true, ...response });
}

async function buildUserPrompt(
    req: z.infer<typeof GenerateScriptRequestSchema>,
    env: Env,
): Promise<string> {
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
    const course = racePackCourse(req);
    if (course) {
        lines.push(
            "",
            "RACE DAY SCRIPT. This is a PRE-BAKED OFFLINE PACK, generated at home the night before the race and played from the phone's own storage:",
            `- The run is the ${course.name} on ${course.date}, 42.2 km, his FIRST full marathon. The first 30 minutes are in a crowd with no phone signal, so this script is the only voice he hears until the network comes back, and it is the fallback for any kilometre the live voices cannot reach him later.`,
            "- He starts the race clock himself at the timing gate; distance 0 is the gate, not the corral.",
            "- ON TOP of the required messages, write ONE-SHOT STORY LINES: {\"type\":\"distance\",\"atMeters\":N}, one for EVERY story in the STORIES ALONG THE COURSE list below, at the metres given (shift each by 150 to 500 m so it never lands on a round kilometre, which another voice owns; keep them in order). You are the tour guide on this run, and the tour guide is Ricky: the fact is true and specific (the last emperor dancing at the Astor, Liddell's Sunday, the bridge where the army met, the walls the occupiers pulled down), the angle is yours, and it lands on HIM, on what he is doing at that moment. Kilometres 1 to 8 are the no-signal stretch: make sure each of them has a line.",
            "- Name the actual places (Chinese names exactly as given, with the English the file gives). Keep every historical fact exactly as the file states it; invent only the jokes. Never recite; one or two sentences of fact per line, then the knife.",
            "- The per-km loop pool: 8 variants, race-flavoured (bibs, crowds, gels, cups, the 30 km wall, his first marathon, the city of jokes), none naming a kilometre.",
            "- The HALFWAY line is the half-marathon mat; the NEAR-FINISH line is the last 100 m along the stadium; the FINISH line is the finish, so this once it IS the end.",
            "- Message count for THIS script: 38 to 48 (the normal 8 to 14 limit does not apply here).",
        );
        for (const l of courseScriptBlock(course)) lines.push(l);
    }
    if (req.skipOpener) {
        lines.push(
            "SKIP THE OPENER: do NOT include a time.atSeconds=0 START ROAST in the script. The opener has already been generated separately and played to the runner. Start the script with the per-km loop, surprise roasts, halfway, etc.",
        );
    }
    if (req.recentRunSummary) {
        lines.push(`Recent: ${req.recentRunSummary}`);
    }
    if (req.userMemory && req.userMemory.length > 0) {
        lines.push("");
        lines.push("PERSONAL TROLL FUEL — FACTS, NOT PHRASES. These are things the runner has told us about themselves. Use the FACTS as material; INVENT a new joke every line. NEVER quote a bullet verbatim — re-phrase, find a fresh angle, change the image. If the bullet says 'X has 10 users', a good line might be 'X's user base would fit in a London cab' or 'X — popular as tonsillitis' — different metaphor, different vocabulary, every time:");
        for (const m of req.userMemory) {
            lines.push(`- ${m}`);
        }
    }
    if (req.likedLineExamples && req.likedLineExamples.length > 0) {
        lines.push("");
        lines.push("LIKED LINES (CALIBRATION ONLY — DO NOT COPY ANY OF THESE). These are lines the runner heart-tagged from past runs. Use them as TEXTURE references — they tell you what length, rhythm, swagger, and specificity hits for THIS runner. You are FORBIDDEN from reusing any phrase, image, name, or punchline from this list. If you find yourself reaching for one, rewrite from scratch:");
        for (const ex of req.likedLineExamples) {
            lines.push(`- "${ex}"`);
        }
    }
    await pushBriefingBlock(lines, env, "ricky", { chance: 1 });
    lines.push("", "Generate the script now. JSON only.");
    return lines.join("\n");
}

function nudgeOffKilometres<T extends { triggerSpec: { type: string; atMeters?: number } }>(messages: T[]): T[] {
    return messages.map((m) => {
        const at = m.triggerSpec.atMeters;
        if (m.triggerSpec.type !== "distance" || at === undefined) return m;
        const rem = at % 1000;
        if (rem >= 200 && rem <= 800) return m;
        const base = rem < 200 ? at - rem : at - rem + 1000;
        return { ...m, triggerSpec: { ...m.triggerSpec, atMeters: base + 350 } };
    });
}

function racePackCourse(req: z.infer<typeof GenerateScriptRequestSchema>) {
    if (req.raceMode !== "actual") return null;
    return (req.courseId ? courseById(req.courseId) : null) ?? courseFor(req.raceMode);
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
