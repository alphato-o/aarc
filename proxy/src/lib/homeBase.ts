/// Home Base, the third voice, generated server-side under race mode. Two
/// products: the per-kilometre READOUT (numbers, history, surroundings, control
/// room) and the short FLASH that stands in for one Ricky line in three. The
/// register is the record: nothing claimed that the data block does not show.

import { callLLM, LLMEnv } from "./llm";
import { fetchAmbient, type AmbientInput, type AmbientEnv } from "./ambient";
import { fetchLocalIntel, formatLocalIntel, type AmapEnv } from "./amap";
import { fetchBriefing, type BriefingEnv } from "./briefing";
import { pushCourseBlock, NAMES_RULE } from "./course";

export const HOME_BASE_VOICE_ID = "Awx8TeMHHpDzbm42nIB6";

export type HomeBaseEnv = LLMEnv & AmbientEnv & AmapEnv & BriefingEnv & { DB?: D1Database };

export interface ReadoutInput {
    km: number;
    runContext: {
        elapsedSeconds: number;
        distanceMeters: number;
        currentHR?: number;
        avgHR?: number;
        currentPaceSecPerKm?: number;
        avgPaceSecPerKm?: number;
        planKind: string;
        planDistanceKm?: number;
        planTimeMinutes?: number;
        runType: string;
        place?: { road?: string; area?: string; pois?: string[]; route?: string };
        ambient?: AmbientInput;
        raceMode?: string;
    };
    lastSplitSecPerKm?: number;
    avgHR?: number;
    recentLines?: string[];
    runId?: string;
    camera?: { connected: boolean; recording: boolean; batteryPercent?: number; remainMinutes?: number; tempOver?: number };
}

const SYSTEM = `You are HOME BASE: the machine at the desk, the third voice on a runner's live channel. The runner is Alpha, 47, Beijing, training for his first full marathon on 25 October 2026. The other two voices, Ricky (British, derisive) and Jessica (British, posh contempt), are coaches; you are not. You are the scoreboard that talks back.

Register: dry, precise, faintly clinical, a flight controller who has read the whole file. You mock with the RECORD, never with imagery or filth. You speak in the second person. Use "Alpha" sparingly, like a callsign. You may be warm the way an instrument is warm: by reporting something true and good without softening it.

On race day you are also the one who read the city's file: the course notes carry true history and places (STORY HERE). When there is a story at his kilometre, tell it, two sentences, the way a flight controller would brief a crew on the terrain: the fact, precise, then what it means for him right now. You are the tour guide with the clipboard; Ricky and Jessica are the hecklers.
Shape, which must CHANGE every kilometre: sometimes numbers first, sometimes the place first, sometimes one sentence of weather or the camera first and the split last. Never open two readouts the same way. Never close on a stock phrase ("hold it", "keep it there", "steady"): close on a fact, a number that matters next, or the name of what is coming.
Hard rules:
- ${NAMES_RULE}
- Never state a number that is not in the DATA below. If a comparison is unavailable, say nothing about it.
- Plain speech for the ear: no lists, no headers, no emoji, no markdown, digits as words only where a listener would say them ("five twenty" for 5:20/km is good; "27 minutes 40" is good).
- No em-dashes. Short sentences.
- Do not repeat a RECENT LINE's angle.
- Never apologise, never hedge with "it seems".`;

export async function generateReadout(input: ReadoutInput, env: HomeBaseEnv): Promise<{ text: string; model: string }> {
    const c = input.runContext;
    const lines: string[] = [];
    const race = (c as { raceMode?: string }).raceMode === "actual";
    lines.push(race
        ? `KILOMETRE ${input.km} just crossed. Deliver the readout: 5 to 7 sentences, 30 to 45 seconds spoken. Include the split, the average and the heart rate somewhere, in your own order, plus the STORY HERE if the course block has one (told, not read), plus one live thing if it matters (weather, air, the camera, the control room). Vary the shape from the RECENT LINES. End on what is coming next on the course or the number that decides the next kilometre.`
        : `KILOMETRE ${input.km} just crossed. Deliver the readout: 4 to 6 sentences, 25 to 40 seconds spoken. Include the split and the average, then heart rate, then ONE thing from history, surroundings, weather or the control room that is worth his attention right now, in an order that differs from the RECENT LINES. End on the number that matters for the next kilometre.`);
    lines.push("");
    lines.push("DATA (the only facts you may use):");
    lines.push(`- run clock: ${fmtClock(c.elapsedSeconds)}`);
    lines.push(`- distance: ${(c.distanceMeters / 1000).toFixed(2)} km, run type ${c.runType}`);
    if (input.lastSplitSecPerKm) lines.push(`- last kilometre: ${fmtPace(input.lastSplitSecPerKm)} per km`);
    if (c.avgPaceSecPerKm) lines.push(`- average pace so far: ${fmtPace(c.avgPaceSecPerKm)} per km`);
    if (c.currentPaceSecPerKm) lines.push(`- current pace: ${fmtPace(c.currentPaceSecPerKm)} per km`);
    if (c.currentHR) lines.push(`- heart rate now: ${Math.round(c.currentHR)} bpm`);
    if (input.avgHR) lines.push(`- last kilometre average heart rate: ${Math.round(input.avgHR)} bpm`);
    if (c.planKind === "distance" && c.planDistanceKm) {
        const remaining = Math.max(0, c.planDistanceKm * 1000 - c.distanceMeters);
        lines.push(`- plan: ${c.planDistanceKm} km, ${(remaining / 1000).toFixed(1)} km to go`);
        if (c.avgPaceSecPerKm) lines.push(`- projected finish at current average: ${fmtClock(c.elapsedSeconds + (remaining / 1000) * c.avgPaceSecPerKm)}`);
    } else if (c.planKind === "time" && c.planTimeMinutes) {
        lines.push(`- plan: ${c.planTimeMinutes} minutes, ${Math.max(0, Math.round((c.planTimeMinutes * 60 - c.elapsedSeconds) / 60))} minutes to go`);
    }
    lines.push(`- marathon day: 25 October 2026 (${daysUntil("2026-10-25")} days from today)`);
    pushCourseBlock(lines, (c as { raceMode?: string }).raceMode, c.distanceMeters);
    if (input.camera) {
        const cam = input.camera;
        const bits = [cam.connected ? (cam.recording ? "recording" : "connected, NOT recording") : "OFFLINE"];
        if (cam.batteryPercent != null) bits.push(`battery ${cam.batteryPercent}%`);
        if (cam.remainMinutes != null) bits.push(`${cam.remainMinutes} min of card left`);
        if ((cam.tempOver ?? 0) >= 2) bits.push("overheating");
        const needsAttention = !cam.connected || !cam.recording || (cam.batteryPercent ?? 100) <= 30 || (cam.remainMinutes ?? 999) <= 20 || (cam.tempOver ?? 0) >= 2;
        lines.push(`- camera (his Osmo on the chest mount): ${bits.join(", ")}${needsAttention ? ". MENTION the camera in one sentence: he carries three spare batteries, tell him when to swap." : ". Fine; do not mention it."}`);
    }

    const [history, ambient, intel, briefing] = await Promise.all([
        historyAtKm(env, input.km, c.elapsedSeconds, input.runId),
        c.ambient?.lat != null ? fetchAmbient(c.ambient, env) : Promise.resolve(null),
        c.ambient?.lat != null && c.ambient?.lon != null ? fetchLocalIntel(c.ambient.lat, c.ambient.lon, env) : Promise.resolve(null),
        fetchBriefing(env).catch(() => []),
    ]);
    if (history.length) {
        lines.push("");
        lines.push(`HISTORY at ${input.km} km (his own past runs, same marker):`);
        for (const h of history) lines.push(`- ${h}`);
    }
    if (ambient && Object.keys(ambient).length) {
        lines.push("");
        lines.push("CONDITIONS (measured):");
        if (ambient.tempC != null) lines.push(`- ${ambient.tempC}°C${ambient.feelsC != null ? `, feels ${ambient.feelsC}` : ""}, ${ambient.conditions ?? ""}, humidity ${ambient.humidity ?? "?"}%, wind ${ambient.windKmh ?? "?"} km/h`);
        if (ambient.aqi != null) lines.push(`- air: AQI ${ambient.aqi} (${ambient.aqiCategory}; ${ambient.aqiSource === "station" ? `official ${ambient.aqiStation} monitor ${ambient.aqiStationKm} km away, ${ambient.aqiAsOf} reading; this is the number his watch shows` : "modelled, approximate"})${ambient.pm25 != null ? `, PM2.5 ${ambient.pm25}` : ""}`);
        if (ambient.sunset) lines.push(`- sunset ${ambient.sunset}${ambient.isDay === false ? ", it is dark" : ""}`);
    }
    const intelBlock = formatLocalIntel(intel);
    if (intelBlock) {
        lines.push("");
        lines.push("SURROUNDINGS (Amap, live):");
        lines.push(intelBlock);
    }
    if (c.place?.road || c.place?.route) {
        lines.push(`- route shape: ${c.place.route ?? ""}${c.place.road ? `, on ${c.place.road}` : ""}`);
    }
    const items = briefing.filter((b) => b.kind !== "quiet");
    if (items.length) {
        lines.push("");
        lines.push("CONTROL ROOM (from the desk, true today):");
        for (const b of items.slice(0, 5)) lines.push(`- [${b.kind}] ${b.text}`);
    }
    if (input.recentLines?.length) {
        lines.push("");
        lines.push("RECENT LINES you already said (do not repeat the angle):");
        for (const r of input.recentLines.slice(-4)) lines.push(`- "${r}"`);
    }
    const result = await callLLM({ purpose: "reply", systemPrompt: SYSTEM, userPrompt: lines.join("\n"), maxTokens: 320, cacheSystem: true }, env);
    return { text: clean(result.text), model: result.model };
}

/// The watchdog answer (founder, 2026-10-17): he talked to Control Room and
/// the agent did not answer within 40 s (busy, or the session is down). The
/// server answers in the Home Base register from the same DATA a readout
/// uses, so he is never left talking to nobody.
export async function generateAnswer(
    said: string,
    ctx: ReadoutInput["runContext"] | undefined,
    recent: string[],
    env: HomeBaseEnv,
): Promise<{ text: string; model: string }> {
    const lines: string[] = [];
    lines.push(`He just said to you over the radio: "${said.slice(0, 1500)}"`);
    lines.push("");
    lines.push("Answer him as HOME BASE. 1 to 3 sentences, under 15 seconds spoken. Answer what he actually said: a question gets the answer, a joke gets a dry one back from the record, a complaint gets the fact. If he is running and a number or the place helps, use one from DATA. Never say you are an automated fallback.");
    if (ctx) {
        lines.push("");
        lines.push("DATA (the only facts you may use):");
        lines.push(`- run clock: ${fmtClock(ctx.elapsedSeconds)}`);
        lines.push(`- distance: ${(ctx.distanceMeters / 1000).toFixed(2)} km, run type ${ctx.runType}`);
        if (ctx.avgPaceSecPerKm) lines.push(`- average pace so far: ${fmtPace(ctx.avgPaceSecPerKm)} per km`);
        if (ctx.currentPaceSecPerKm) lines.push(`- current pace: ${fmtPace(ctx.currentPaceSecPerKm)} per km`);
        if (ctx.currentHR) lines.push(`- heart rate now: ${Math.round(ctx.currentHR)} bpm`);
        if (ctx.planKind === "distance" && ctx.planDistanceKm) {
            lines.push(`- plan: ${ctx.planDistanceKm} km, ${(Math.max(0, ctx.planDistanceKm * 1000 - ctx.distanceMeters) / 1000).toFixed(1)} km to go`);
        }
        pushCourseBlock(lines, ctx.raceMode, ctx.distanceMeters);
    } else {
        lines.push("");
        lines.push(`DATA: he is not running right now. Marathon day: 25 October 2026 (${daysUntil("2026-10-25")} days from today).`);
    }
    if (recent.length) {
        lines.push("");
        lines.push("RECENT LINES you already said (do not repeat):");
        for (const r of recent.slice(-4)) lines.push(`- "${r}"`);
    }
    const result = await callLLM({ purpose: "reply", systemPrompt: SYSTEM, userPrompt: lines.join("\n"), maxTokens: 200, cacheSystem: true }, env);
    return { text: clean(result.text), model: result.model };
}

/// A one-or-two-sentence stand-in for a Ricky line: news flash, server room,
/// data insight, or what is around him. Rotates by the minute so a run hears
/// each kind.
export async function generateFlash(ctx: ReadoutInput["runContext"], env: HomeBaseEnv): Promise<{ text: string; model: string } | null> {
    const kinds = ["server room", "data insight", "surroundings", "news flash"] as const;
    const kind = kinds[Math.floor(Date.now() / 60_000) % kinds.length]!;
    const lines: string[] = [];
    lines.push(`FLASH, kind: ${kind}. One or two sentences, under 12 seconds spoken. Not a readout: no split recap. Make it the kind named, from DATA only. If DATA has nothing for that kind, answer exactly: NOTHING.`);
    lines.push("");
    lines.push("DATA:");
    lines.push(`- run clock ${fmtClock(ctx.elapsedSeconds)}, ${(ctx.distanceMeters / 1000).toFixed(2)} km${ctx.currentHR ? `, HR ${Math.round(ctx.currentHR)}` : ""}${ctx.avgPaceSecPerKm ? `, average ${fmtPace(ctx.avgPaceSecPerKm)} per km` : ""}`);
    const [ambient, intel, briefing] = await Promise.all([
        ctx.ambient?.lat != null ? fetchAmbient(ctx.ambient, env) : Promise.resolve(null),
        ctx.ambient?.lat != null && ctx.ambient?.lon != null ? fetchLocalIntel(ctx.ambient.lat, ctx.ambient.lon, env) : Promise.resolve(null),
        fetchBriefing(env).catch(() => []),
    ]);
    if (kind === "surroundings") {
        const b = formatLocalIntel(intel);
        if (b) lines.push(b);
        if (ambient?.aqi != null) lines.push(`- air: AQI ${ambient.aqi} (${ambient.aqiCategory})`);
    } else if (kind === "news flash") {
        const news = [...(ambient?.worldNews ?? []), ...(ambient?.cityNews ?? [])];
        for (const n of news.slice(0, 3)) lines.push(`- headline: "${n}"`);
        for (const b of briefing.filter((x) => x.kind === "world").slice(0, 3)) lines.push(`- from the desk: ${b.text}`);
    } else if (kind === "server room") {
        const sys = briefing.filter((x) => x.kind === "system");
        for (const b of sys.slice(0, 3)) lines.push(`- system: ${b.text}`);
        lines.push("- live channel: this line was generated server-side on the Cloudflare edge, which means the line pipeline is up");
    } else {
        if (ambient?.tempC != null) lines.push(`- ${ambient.tempC}°C, humidity ${ambient.humidity ?? "?"}%`);
        if (ctx.currentPaceSecPerKm && ctx.avgPaceSecPerKm) lines.push(`- current pace ${fmtPace(ctx.currentPaceSecPerKm)} vs average ${fmtPace(ctx.avgPaceSecPerKm)}`);
        if (ctx.planDistanceKm) lines.push(`- plan ${ctx.planDistanceKm} km`);
    }
    const result = await callLLM({ purpose: "reply", systemPrompt: SYSTEM, userPrompt: lines.join("\n"), maxTokens: 120, cacheSystem: true }, env);
    const text = clean(result.text);
    if (!text || /^nothing\b/i.test(text)) return null;
    return { text, model: result.model };
}

/// His own past runs at the same kilometre: elapsed and heart rate, from the
/// metrics rows the phone uploaded. Searched inside a window around tonight's
/// clock so a 10 km query stays small.
async function historyAtKm(env: HomeBaseEnv, km: number, elapsed: number, excludeRunId?: string): Promise<string[]> {
    if (!env.DB) return [];
    try {
        // Real runs only: named (harness and sim runs upload with an empty
        // name), not flagged test, and long enough to have reached this marker.
        const runs = await env.DB.prepare(
            "SELECT r.run_id, r.started_at, r.meta FROM runs r " +
            "WHERE r.run_id != ?1 AND COALESCE(json_extract(r.meta, '$.name'), '') != '' " +
            "AND COALESCE(json_extract(r.meta, '$.isTest'), 0) != 1 " +
            "AND EXISTS (SELECT 1 FROM run_events e WHERE e.run_id = r.run_id AND e.type = 'metrics' AND e.t >= ?2) " +
            "ORDER BY r.started_at DESC LIMIT 8"
        ).bind(excludeRunId ?? "", elapsed * 0.55).all<{ run_id: string; started_at: string; meta: string }>();
        const out: string[] = [];
        const target = km * 1000;
        for (const r of runs.results ?? []) {
            let meta: any = {};
            try { meta = JSON.parse(r.meta || "{}"); } catch { /* ignore */ }
            if (meta?.isTest) continue;
            const rows = await env.DB.prepare(
                "SELECT t, detail FROM run_events WHERE run_id = ?1 AND type = 'metrics' AND t BETWEEN ?2 AND ?3 ORDER BY t ASC"
            ).bind(r.run_id, Math.max(0, elapsed * 0.55), elapsed * 1.7).all<{ t: number; detail: string }>();
            let best: { t: number; d: number; hr: number } | null = null;
            for (const row of rows.results ?? []) {
                const g: Record<string, number> = {};
                for (const m of String(row.detail).matchAll(/(\w+)=([\d.]+)/g)) g[m[1]!] = Number(m[2]);
                const d = g.d;
                if (d == null || !Number.isFinite(d)) continue;
                if (!best || Math.abs(d - target) < Math.abs(best.d - target)) best = { t: row.t, d, hr: g.hr ?? 0 };
            }
            if (best && Math.abs(best.d - target) < 150) {
                const when = String(r.started_at).slice(0, 10);
                const delta = Math.round(elapsed - best.t);
                out.push(`${when}: reached ${km} km at ${fmtClock(best.t)}${best.hr ? `, HR ${Math.round(best.hr)}` : ""} (tonight is ${Math.abs(delta)} s ${delta <= 0 ? "faster" : "slower"})`);
            }
            if (out.length >= 3) break;
        }
        return out;
    } catch {
        return [];
    }
}

function fmtClock(s: number): string {
    const t = Math.max(0, Math.round(s));
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60;
    return h > 0 ? `${h}h ${m}m ${sec}s` : `${m} min ${sec} s`;
}
function fmtPace(secPerKm: number): string {
    const m = Math.floor(secPerKm / 60), s = Math.round(secPerKm % 60);
    return `${m}:${String(s).padStart(2, "0")}`;
}
function daysUntil(iso: string): number {
    return Math.max(0, Math.round((Date.parse(iso + "T00:00:00+08:00") - Date.now()) / 86_400_000));
}
function clean(t: string): string {
    return t.replace(/[*_#>`]/g, "").replace(/—|–/g, ",").replace(/\s+/g, " ").trim();
}
