import { z } from "zod";
import { softStrings } from "../schemas";
import { systemPromptFor } from "../lib/personalities";
import { HOME_BASE_SYSTEM } from "../lib/homeBase";
import { courseById, courseScriptBlock, Course } from "../lib/course";
import { callLLMJSON, LLMOutputError, describeUpstreamError, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";

export type Env = LLMEnv & SentryEnv;

/// The race pack's other two voices (founder, 2026-10-19: "your pack should
/// include jess, and you yourself"). Built at home the night before with the
/// Ricky script, so the no-signal first half hour still has all three.
const RequestSchema = z.object({
    courseId: z.string().min(1),
    personalNotes: softStrings(24, 400),
});

const LineSchema = z.object({ km: z.number().int().min(0).max(46), text: z.string().min(4).max(400) });
const OutputSchema = z.object({ lines: z.array(LineSchema).min(10).max(60) });
type Line = z.infer<typeof LineSchema>;

export async function racePackVoicesHandler(request: Request, env: Env): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "invalid json" }, { status: 400 });
    }
    const parsed = RequestSchema.safeParse(body);
    if (!parsed.success) {
        return json({ ok: false, error: "invalid request", details: parsed.error.format() }, { status: 400 });
    }
    const course = courseById(parsed.data.courseId);
    const jessicaSystem = systemPromptFor("jessica", "react_medium");
    if (!course || !jessicaSystem) return json({ ok: false, error: "unknown course" }, { status: 400 });

    try {
        const [jessica, home] = await Promise.all([
            generate(env, jessicaSystem, jessicaPrompt(course, parsed.data.personalNotes ?? [])),
            generate(env, HOME_BASE_SYSTEM, homePrompt(course)),
        ]);
        return json({ ok: true, jessica, home });
    } catch (e) {
        if (e instanceof LLMOutputError) {
            await captureMessage(env, `race-pack-voices rejected after retry: ${e.detail}`, "error", { route: "/race-pack-voices" });
            return json({ ok: false, error: "model output failed schema validation" }, { status: 502 });
        }
        const desc = describeUpstreamError(e);
        return json({ ok: false, error: "upstream", detail: desc.message }, { status: desc.httpStatus });
    }
}

async function generate(env: Env, systemPrompt: string, userPrompt: string): Promise<Line[]> {
    const out = await callLLMJSON(
        { purpose: "script", systemPrompt, userPrompt, maxTokens: 8000, cacheSystem: true },
        env,
        (raw) => {
            const v = OutputSchema.safeParse(JSON.parse(stripCodeFences(raw)));
            if (!v.success) throw new Error("failed schema: " + JSON.stringify(v.error.issues.slice(0, 2)));
            return v.data.lines;
        },
    );
    return out.data;
}

function jessicaPrompt(course: Course, notes: string[]): string {
    const lines: string[] = [];
    lines.push("This is the night before his first marathon. Write your lines for the race now: they are cached on his phone and played while the phone has no signal, so nothing live reaches you. Each is tied to a kilometre and fires somewhere in that kilometre, in between Ricky and the music.");
    lines.push("");
    lines.push("RACE DAY: you are exactly the same Jessica, same character, same energy, same appetite. Only less explicit: hint, don't spell it out. Innuendo, double meaning, a knowing pause; let him fill in the rest. Nothing a broadcast would have to bleep.");
    for (const l of courseScriptBlock(course)) lines.push(l);
    if (notes.length) {
        lines.push("");
        lines.push("PERSONAL FUEL, facts not phrases; a different one (or none) per line:");
        for (const n of notes) lines.push(`- ${n}`);
    }
    lines.push("");
    lines.push("RULES:");
    lines.push("1. 36 lines. Sparse early, dense late: about 8 across km 1-14, 12 across km 15-28, 16 across km 29-42. Never two on the same km.");
    lines.push("2. Most lines hang on the place at their km (a street, a landmark, the river, a station); the rest on the state of him at that point of a marathon. Never state his pace, heart rate or time: you cannot see them.");
    lines.push("3. One to three sentences, at most ~260 characters. Every line a different angle, image and opening.");
    lines.push("4. At most a third carry one audio tag ([sighs]/[laughs]/[chuckles]/[exhales]).");
    lines.push("5. Follow your run arc by km: pure contempt early; from about km 25 still cruel but grudging; past km 32 warmer under the ice, the reward feeling closer.");
    lines.push("6. No em-dashes.");
    lines.push("");
    lines.push('Return ONLY JSON: {"lines": [{"km": 3, "text": "..."}, ...]}');
    return lines.join("\n");
}

function homePrompt(course: Course): string {
    const lines: string[] = [];
    lines.push("This is the night before the race. Write your kilometre readouts now, one for every kilometre from 1 to 42. They are cached on his phone for the stretches with no signal, where you cannot see his numbers: so no pace, no heart rate, no time, no comparisons. Ricky announces the kilometre itself; you brief the ground.");
    for (const l of courseScriptBlock(course)) lines.push(l);
    lines.push("");
    lines.push("RULES:");
    lines.push("1. One line per km, km 1 to 42, 42 lines. Each says where he is and what is next on the course: the water or the medical point coming, the turn, the bridge, the story at that point.");
    lines.push("2. One or two short sentences, at most ~200 characters. The kilometre number may appear; no other number that is not in the course file.");
    lines.push("3. Change the shape every kilometre; never open two the same way. Close on a fact or the name of what is coming.");
    lines.push("4. No em-dashes.");
    lines.push("");
    lines.push('Return ONLY JSON: {"lines": [{"km": 1, "text": "..."}, ...]}');
    return lines.join("\n");
}

function stripCodeFences(text: string): string {
    const t = text.trim();
    return t.startsWith("```") ? t.replace(/^```(?:json)?\s*\n?/, "").replace(/\n?```\s*$/, "").trim() : t;
}

function json(data: unknown, init: ResponseInit = {}): Response {
    return new Response(JSON.stringify(data), { ...init, headers: { "content-type": "application/json", ...(init.headers ?? {}) } });
}
