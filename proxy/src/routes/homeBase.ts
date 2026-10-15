/// POST /home-base/readout — race mode: Home Base calls the kilometre in its
/// own voice. Same envelope as /dynamic-line plus `voiceId` so the phone plays
/// it as Kristen, not as a coach.

import { HomeBaseReadoutRequestSchema } from "../schemas";
import { generateReadout, HOME_BASE_VOICE_ID, type HomeBaseEnv } from "../lib/homeBase";
import { describeUpstreamError } from "../lib/llm";

const json = (data: unknown, status = 200): Response =>
    new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

export async function homeBaseReadoutHandler(request: Request, env: HomeBaseEnv): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "bad json" }, 400);
    }
    const parsed = HomeBaseReadoutRequestSchema.safeParse(body);
    if (!parsed.success) return json({ ok: false, error: "invalid request", details: parsed.error.format() }, 400);
    try {
        const r = await generateReadout(parsed.data, env);
        return json({ ok: true, text: r.text, model: r.model, voiceId: HOME_BASE_VOICE_ID });
    } catch (e) {
        const d = describeUpstreamError(e);
        return json({ ok: false, error: "upstream", detail: d.message }, d.httpStatus >= 400 ? d.httpStatus : 502);
    }
}
