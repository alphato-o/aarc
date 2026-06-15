/// GET/POST /ambient — resolve the real-time ambient context (weather, AQI,
/// sun, news) for a location + clock, and return BOTH the structured values and
/// the exact prompt block that gets fed to the coaches. The app calls this
/// during a run and logs the result so the Control Room can show what real
/// ambient data was fetched + put into the script-generation context.

import { fetchAmbient, pushAmbientBlock, type AmbientInput } from "../lib/ambient";

const json = (data: unknown): Response =>
    new Response(JSON.stringify(data), {
        headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
    });

export async function ambientHandler(request: Request): Promise<Response> {
    let input: AmbientInput = {};
    try {
        input = ((await request.json()) as AmbientInput) ?? {};
    } catch {
        return new Response("bad json", { status: 400 });
    }
    const resolved = await fetchAmbient(input);
    const lines: string[] = [];
    pushAmbientBlock(lines, input, resolved);
    return json({ resolved, block: lines.join("\n") });
}
