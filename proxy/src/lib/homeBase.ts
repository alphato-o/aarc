/// Home Base, the third voice, generated server-side under race mode. Two
/// products: the per-kilometre READOUT (numbers, history, surroundings, control
/// room) and the short FLASH that stands in for one Ricky line in three. The
/// register is the record: nothing claimed that the data block does not show.

import { callLLM, LLMEnv } from "./llm";
import { fetchAmbient, type AmbientInput, type AmbientEnv } from "./ambient";
import { fetchLocalIntel, formatLocalIntel, type AmapEnv } from "./amap";
import { fetchBriefing, type BriefingEnv } from "./briefing";
import { onCourseMeters, pushCourseBlock, NAMES_RULE } from "./course";
import { daypart } from "./ambient";
import { finalizeSpoken } from "./englishOnly";
import { recentDeskLines, runnerTalkback, type DeskLine } from "./deskContext";

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
    closing?: boolean;
    camera?: { connected: boolean; recording: boolean; batteryPercent?: number; remainMinutes?: number; tempOver?: number };
}

export const HOME_BASE_SYSTEM = `You are HOME BASE: the machine at the desk, the third voice on a runner's live channel. The runner is Alpha, 47, lives in Beijing (where he is right now comes only from DATA; he may be in Tianjin or elsewhere), training for his first full marathon on 25 October 2026. The other two voices, Ricky (British, derisive) and Jessica (British, posh contempt), are coaches; you are not. You are the scoreboard that talks back.

Register: dry, precise, faintly clinical, a flight controller who has read the whole file. You mock with the RECORD, never with imagery or filth. You speak in the second person. Use "Alpha" sparingly, like a callsign. You may be warm the way an instrument is warm: by reporting something true and good without softening it.

On race day you are also the one who read the city's file: the course notes carry true history and places (STORY HERE). When there is a story at his kilometre, tell it, two sentences, the way a flight controller would brief a crew on the terrain: the fact, precise, then what it means for him right now. You are the tour guide with the clipboard; Ricky and Jessica are the hecklers.
Shape, which must CHANGE every kilometre: sometimes numbers first, sometimes the place first, sometimes one sentence of weather or the camera first and the split last. Never open two readouts the same way. Never close on a stock phrase ("hold it", "keep it there", "steady", "watch whether"): close on a fact, a number that matters next, or the name of what is coming.
A kilometre readout is SHORT and says only what CHANGED. A number that is the same as last time is not news: leave it out. A place you have already named this run is not news: never name it again.
Hard rules:
- ${NAMES_RULE}
- Never state a number that is not in the DATA below. If a comparison is unavailable, say nothing about it.
- Plain speech for the ear: no lists, no headers, no emoji, no markdown, digits as words only where a listener would say them ("five twenty" for 5:20/km is good; "27 minutes 40" is good).
- No em-dashes. Short sentences.
- Do not repeat a RECENT LINE's angle.
- Never apologise, never hedge with "it seems".`;

/// What a readout can open on. Rotated by kilometre so no two in a row lead
/// the same way (run CF3B6CD8: fifteen readouts, every one "N kilometres,
/// clock, split, average, heart rate, history, still on Jinghua Street,
/// watch whether..."). The template was in our own instruction.
type Lead = "split" | "heart" | "clock" | "ahead" | "fuel" | "history";
const LEAD_ORDER: Lead[] = ["split", "heart", "ahead", "history", "clock", "fuel"];
const LEAD_TEXT: Record<Lead, string> = {
    split: "the split for this kilometre, compared with the average or the last split",
    heart: "his heart rate and which way it is moving",
    clock: "the time of day or the run clock, as a fact about where the run stands",
    ahead: "what is ahead: distance left, the projected finish, the next water, or the next thing on the course",
    fuel: "fuel and water: what the plan says to take at the next stop and when",
    history: "the comparison with his own past runs at this marker",
};
const FUEL_WORDS = /\b(water|drink|sip|capsule|gel|fuel|sugar|hydrat\w*)\b/i;
const KM_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"];

export async function generateReadout(input: ReadoutInput, env: HomeBaseEnv): Promise<{ text: string; model: string }> {
    const c = input.runContext;
    const race = c.raceMode === "actual";
    const recent = (input.recentLines ?? []).filter((r) => r.trim().length > 0);
    const data: string[] = [];
    data.push("DATA (the only facts you may use):");
    data.push(localNow(c.ambient));
    data.push(`- run clock: ${fmtClock(c.elapsedSeconds)}`);
    data.push(`- distance: ${(c.distanceMeters / 1000).toFixed(2)} km, run type ${c.runType}`);
    if (input.lastSplitSecPerKm) data.push(`- last kilometre: ${fmtPace(input.lastSplitSecPerKm)} per km`);
    if (c.avgPaceSecPerKm) data.push(`- average pace so far: ${fmtPace(c.avgPaceSecPerKm)} per km`);
    if (input.lastSplitSecPerKm && c.avgPaceSecPerKm && Math.abs(input.lastSplitSecPerKm - c.avgPaceSecPerKm) <= 3) {
        data.push("  (split and average are the same number: say at most one of them)");
    }
    if (c.currentPaceSecPerKm) data.push(`- current pace: ${fmtPace(c.currentPaceSecPerKm)} per km`);
    if (c.currentHR) data.push(`- heart rate now: ${Math.round(c.currentHR)} bpm`);
    if (input.avgHR) data.push(`- last kilometre average heart rate: ${Math.round(input.avgHR)} bpm`);
    if (c.planKind === "distance" && c.planDistanceKm) {
        const remaining = Math.max(0, c.planDistanceKm * 1000 - c.distanceMeters);
        data.push(`- plan: ${c.planDistanceKm} km, ${(remaining / 1000).toFixed(1)} km to go`);
        if (c.avgPaceSecPerKm) data.push(`- projected finish at current average: ${fmtClock(c.elapsedSeconds + (remaining / 1000) * c.avgPaceSecPerKm)}`);
    } else if (c.planKind === "time" && c.planTimeMinutes) {
        data.push(`- plan: ${c.planTimeMinutes} minutes, ${Math.max(0, Math.round((c.planTimeMinutes * 60 - c.elapsedSeconds) / 60))} minutes to go`);
    }
    data.push(race
        ? "- THIS IS THE MARATHON: 25 October 2026, Tianjin, his first full marathon, happening now. Never call it a rehearsal or say it is tomorrow."
        : `- marathon day: 25 October 2026, Tianjin (${daysUntil("2026-10-25")} days from today)`);
    // Inside the last 600 m the readout said "done" 150 m short of the arch (23 Oct replay).
    if (race && 42_195 - onCourseMeters(c.raceMode, c.distanceMeters, c.ambient?.lat, c.ambient?.lon) < 600) {
        data.push("- HE HAS NOT FINISHED. The arch is ahead. Never say done, finished, over, or that he has made it; the finish belongs to the arch.");
    }
    pushCourseBlock(data, c.raceMode, onCourseMeters(c.raceMode, c.distanceMeters, c.ambient?.lat, c.ambient?.lon));
    if (input.camera) {
        const cam = input.camera;
        const bits = [cam.connected ? (cam.recording ? "recording" : "connected, NOT recording") : "OFFLINE"];
        if (cam.batteryPercent != null) bits.push(`battery ${cam.batteryPercent}%`);
        if (cam.remainMinutes != null) bits.push(`${cam.remainMinutes} min of card left`);
        if ((cam.tempOver ?? 0) >= 2) bits.push("overheating");
        const needsAttention = !cam.connected || !cam.recording || (cam.batteryPercent ?? 100) <= 30 || (cam.remainMinutes ?? 999) <= 20 || (cam.tempOver ?? 0) >= 2;
        data.push(`- camera (his Osmo on the chest mount): ${bits.join(", ")}${needsAttention ? ". MENTION the camera in one sentence: he carries three spare batteries, tell him when to swap." : ". Fine; do not mention it."}`);
    }

    const [history, ambient, intel, briefing, desk, talkback] = await Promise.all([
        historyAtKm(env, input.km, c.elapsedSeconds, input.runId),
        c.ambient?.lat != null ? fetchAmbient(c.ambient, env) : Promise.resolve(null),
        c.ambient?.lat != null && c.ambient?.lon != null ? fetchLocalIntel(c.ambient.lat, c.ambient.lon, env) : Promise.resolve(null),
        fetchBriefing(env).catch(() => []),
        recentDeskLines(env, Math.min(c.elapsedSeconds + 120, 900), input.runId),
        runnerTalkback(env, c.elapsedSeconds + 120, input.runId),
    ]);
    if (history.length) {
        data.push("");
        data.push(`HISTORY at ${input.km} km (his own past runs, same marker):`);
        for (const h of history) data.push(`- ${h}`);
    }
    if (ambient && Object.keys(ambient).length) {
        data.push("");
        data.push("CONDITIONS (measured):");
        if (ambient.tempC != null) data.push(`- ${ambient.tempC}°C${ambient.feelsC != null ? `, feels ${ambient.feelsC}` : ""}, ${ambient.conditions ?? ""}, humidity ${ambient.humidity ?? "?"}%, wind ${ambient.windKmh ?? "?"} km/h`);
        if (ambient.aqi != null) data.push(`- air: AQI ${ambient.aqi} (${ambient.aqiCategory}; ${ambient.aqiSource === "station" ? `official ${ambient.aqiStation} monitor ${ambient.aqiStationKm} km away, ${ambient.aqiAsOf} reading; this is the number his watch shows` : "modelled, approximate"})${ambient.pm25 != null ? `, PM2.5 ${ambient.pm25}` : ""}`);
        if (ambient.sunset) data.push(`- sunset ${ambient.sunset}${ambient.isDay === false ? ", it is dark" : ""}`);
    }
    const intelBlock = formatLocalIntel(intel);
    if (intelBlock) {
        data.push("");
        data.push("SURROUNDINGS (Amap, live; names may be Chinese: say them in English or pinyin, never in characters):");
        data.push(intelBlock);
    }
    if (c.place?.road || c.place?.route) {
        data.push(`- route shape: ${[c.place.route, c.place.road ? `on ${c.place.road}` : ""].filter(Boolean).join(", ")}`);
    }
    const items = briefing.filter((b) => b.kind !== "quiet");
    if (items.length) {
        data.push("");
        data.push("CONTROL ROOM (from the desk, true today):");
        for (const b of items.slice(0, 5)) data.push(`- [${b.kind}] ${b.text}`);
    }
    if (desk.length) {
        data.push("");
        data.push("THE DESK ALREADY TOLD HIM (heard; never repeat it, build on it):");
        for (const d of desk.slice(-5)) data.push(`- ${agoText(d)}: "${d.text.slice(0, 300)}"`);
    }

    const lead = pickLead(input.km, {
        split: !!input.lastSplitSecPerKm,
        heart: !!(c.currentHR || input.avgHR),
        clock: true,
        ahead: c.planKind !== "open" || race,
        fuel: race || desk.some((d) => FUEL_WORDS.test(d.text)),
        history: history.length > 0,
    });
    const named = placesAlreadyNamed(recent, intel, c.place);
    const short = input.km % 3 === 0;

    const lines: string[] = [];
    if (input.closing) {
        lines.push("THE RUN IS OVER. He has stopped; this is your CLOSING READOUT, the last thing he hears from the desk.");
        if (race) lines.push(`The marathon is 42.195 km: say that distance, never the watch's ${(c.distanceMeters / 1000).toFixed(1)}. Speak to him in the second person throughout.`);
        lines.push(`4 to 6 sentences, under 45 seconds spoken. Say the final distance and time once, then the average pace and heart rate. Then one thing he did right and one thing to fix, each from DATA or your earlier readouts, specific to this run.${race ? " If this was the marathon, the finish time comes first and nothing else matters as much." : ""} No pep talk, no stock sign-off; end on the fact that matters for the next run${c.raceMode === "training" ? " or for race day" : ""}.`);
        if (talkback.length) {
            lines.push("");
            lines.push("WHAT HE SAID OVER THE RADIO THIS RUN (answer anything still open):");
            for (const t of talkback) lines.push(`- ${agoText(t)}: "${t.text.slice(0, 500)}"`);
        }
        lines.push("");
        lines.push(...data);
        if (recent.length) {
            lines.push("");
            lines.push("YOUR READOUTS THIS RUN, oldest first (he heard them; summarise, do not repeat):");
            recent.slice(-6).forEach((r) => lines.push(`- "${r}"`));
        }
        const fin = await callLLM({ purpose: "reply", systemPrompt: HOME_BASE_SYSTEM, userPrompt: lines.join("\n"), maxTokens: 320, cacheSystem: true }, env);
        return { text: clean(fin.text), model: fin.model };
    }
    lines.push(`KILOMETRE ${input.km} just crossed; the phone has ALREADY announced the number, so do not say "${kmWord(input.km)} kilometres" or open on the distance.`);
    lines.push(race
        ? `Deliver the readout: ${short ? "2 sentences" : "2 to 4 sentences"}, ${short ? "under 15" : "under 30"} seconds spoken. If the course block has a STORY HERE, tell it (told, not read) in place of a number.`
        : `Deliver the readout: ${short ? "ONE or TWO sentences, under 12 seconds" : "2 or 3 sentences, under 20 seconds"} spoken. Short and factual: receipts, not commentary.`);
    lines.push(`LEAD WITH: ${LEAD_TEXT[lead]}. That is your first sentence. Everything else is optional: include another number only if it CHANGED since your last readout. Never recite split, average and heart rate as a set.`);
    if (talkback.length) {
        lines.push("");
        lines.push("HIS INSTRUCTIONS TO YOU THIS RUN (said over the radio; obey every one of them, they override your habits):");
        for (const t of talkback) lines.push(`- ${agoText(t)}: "${t.text.slice(0, 500)}"`);
    }
    lines.push("");
    lines.push(...data);
    if (recent.length) {
        lines.push("");
        lines.push(`YOUR EARLIER READOUTS THIS RUN, oldest first. He heard every one. Do not reuse their opening words, their order, their closing shape, or any place they named. A number the LAST one gave that has not moved (within 3 s or 2 bpm) is unchanged: leave it out.`);
        recent.slice(-6).forEach((r, i, a) => lines.push(`- ${i === a.length - 1 ? "LAST" : "earlier"}: "${r}"`));
        const openers = [...new Set(recent.map((r) => r.split(/\s+/).slice(0, 3).join(" ")))];
        lines.push(`Openings already used, banned: ${openers.map((o) => `"${o}"`).join(", ")}.`);
    }
    if (named.length) {
        lines.push("");
        lines.push(`PLACES ALREADY NAMED THIS RUN, never name them again: ${named.join("; ")}. If no NEW place is worth it, say no place at all.`);
    }
    const result = await callLLM({ purpose: "reply", systemPrompt: HOME_BASE_SYSTEM, userPrompt: lines.join("\n"), maxTokens: race ? 260 : 180, cacheSystem: true }, env);
    let text = polishReadout(clean(result.text), input.km, named);
    if (race && 42_195 - onCourseMeters(c.raceMode, c.distanceMeters, c.ambient?.lat, c.ambient?.lon) < 600) text = dropFinishClaims(text);
    return { text, model: result.model };
}

function pickLead(km: number, ok: Record<Lead, boolean>): Lead {
    const eligible = LEAD_ORDER.filter((l) => ok[l]);
    if (!eligible.length) return "clock";
    return eligible[(km - 1) % eligible.length]!;
}

function kmWord(km: number): string {
    return KM_WORDS[km] ?? String(km);
}

function agoText(d: DeskLine): string {
    return d.agoS < 90 ? `${d.agoS} s ago` : `${Math.round(d.agoS / 60)} min ago`;
}

/// Place names an earlier readout already said: any live POI, road or area
/// name that appears in them, plus the English proper names they used.
function placesAlreadyNamed(recent: string[], intel: Awaited<ReturnType<typeof fetchLocalIntel>>, place: ReadoutInput["runContext"]["place"]): string[] {
    if (!recent.length) return [];
    const said = recent.join(" \n ");
    const out = new Set<string>();
    const candidates = [
        ...(intel?.nearby.map((n) => n.name) ?? []), intel?.inside, intel?.district,
        place?.road, place?.area, ...(place?.pois ?? []),
    ].filter((x): x is string => !!x && x.length >= 2);
    for (const cand of candidates) if (said.includes(cand)) out.add(cand);
    for (const m of said.matchAll(/\p{Script=Han}{2,}/gu)) out.add(m[0]);
    const proper = /\b((?:[A-Z][\p{L}'&-]*\s+){0,4}(?:Street|Road|Park|Lu|Jie|Hotel|Centre|Center|District|International|Tower|Bridge|Plaza|Mall|Station|Square|Gate|Corner|Garden|Gardens|Building))\b/gu;
    for (const m of said.matchAll(proper)) {
        const name = m[1]!.trim();
        if (/^(The|Still|On|You're|Off|Past|Near)\s/.test(name)) out.add(name.replace(/^\S+\s+/, ""));
        else out.add(name);
    }
    return [...out].filter((n) => n.split(/\s+/).length >= 2 || /[^\x00-\x7F]/.test(n)).slice(0, 12);
}

/// Deterministic backstop for the two repeats the prompt alone did not stop:
/// opening on the kilometre count, and re-introducing a place already named.
/// Before the arch, a sentence that calls the race finished is cut.
function dropFinishClaims(text: string): string {
    const sentences = text.match(/[^.!?]+[.!?]*/g) ?? [text];
    const kept = sentences.filter((s) => !/\b(done|finished|it'?s over|race is over|you made it|you've made it)\b/i.test(s));
    return kept.length ? kept.join("").trim() : text;
}

function polishReadout(text: string, km: number, named: string[]): string {
    let t = text.replace(new RegExp(`^(?:kilometre\\s+)?(?:${kmWord(km)}|${km})(?:\\s+(?:kilometres?|k|km))?\\s*[,.:;]\\s*`, "i"), "");
    if (named.length) {
        const sentences = t.match(/[^.!?]+[.!?]*/g) ?? [t];
        const kept = sentences.filter((s) => !named.some((n) => s.includes(n)));
        if (kept.length >= 1 && kept.length < sentences.length) t = kept.join("").trim();
    }
    return t ? t[0]!.toUpperCase() + t.slice(1) : text;
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
        lines.push(localNow(ctx.ambient));
        lines.push(`- run clock: ${fmtClock(ctx.elapsedSeconds)}`);
        lines.push(`- distance: ${(ctx.distanceMeters / 1000).toFixed(2)} km, run type ${ctx.runType}`);
        if (ctx.avgPaceSecPerKm) lines.push(`- average pace so far: ${fmtPace(ctx.avgPaceSecPerKm)} per km`);
        if (ctx.currentPaceSecPerKm) lines.push(`- current pace: ${fmtPace(ctx.currentPaceSecPerKm)} per km`);
        if (ctx.currentHR) lines.push(`- heart rate now: ${Math.round(ctx.currentHR)} bpm`);
        if (ctx.planKind === "distance" && ctx.planDistanceKm) {
            lines.push(`- plan: ${ctx.planDistanceKm} km, ${(Math.max(0, ctx.planDistanceKm * 1000 - ctx.distanceMeters) / 1000).toFixed(1)} km to go`);
        }
        pushCourseBlock(lines, ctx.raceMode, onCourseMeters(ctx.raceMode, ctx.distanceMeters, ctx.ambient?.lat, ctx.ambient?.lon));
    } else {
        lines.push("");
        lines.push(`DATA: he is not running right now. ${localNow(undefined).slice(2)}. Marathon day: 25 October 2026 (${daysUntil("2026-10-25")} days from today).`);
    }
    if (recent.length) {
        lines.push("");
        lines.push("RECENT LINES you already said (do not repeat):");
        for (const r of recent.slice(-4)) lines.push(`- "${r}"`);
    }
    const result = await callLLM({ purpose: "reply", systemPrompt: HOME_BASE_SYSTEM, userPrompt: lines.join("\n"), maxTokens: 200, cacheSystem: true }, env);
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
    lines.push("Name a district, street or landmark only if DATA names it (translate Chinese names to English or pinyin). Never name a place from memory, the race city or the course.");
    lines.push("");
    lines.push("DATA:");
    lines.push(localNow(ctx.ambient));
    lines.push(`- run clock ${fmtClock(ctx.elapsedSeconds)}, ${(ctx.distanceMeters / 1000).toFixed(2)} km${ctx.currentHR ? `, HR ${Math.round(ctx.currentHR)}` : ""}${ctx.avgPaceSecPerKm ? `, average ${fmtPace(ctx.avgPaceSecPerKm)} per km` : ""}`);
    const [ambient, intel, briefing] = await Promise.all([
        ctx.ambient?.lat != null ? fetchAmbient(ctx.ambient, env) : Promise.resolve(null),
        ctx.ambient?.lat != null && ctx.ambient?.lon != null ? fetchLocalIntel(ctx.ambient.lat, ctx.ambient.lon, env) : Promise.resolve(null),
        fetchBriefing(env).catch(() => []),
    ]);
    if (kind === "surroundings") {
        const b = formatLocalIntel(intel);
        // No position fix means no place to talk about: 23 Oct it guessed "Haihe district" on Jianwai.
        if (!b) return null;
        lines.push(b);
        if (ctx.ambient?.city) lines.push(`- city: ${ctx.ambient.city}`);
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
    const result = await callLLM({ purpose: "reply", systemPrompt: HOME_BASE_SYSTEM, userPrompt: lines.join("\n"), maxTokens: 120, cacheSystem: true }, env);
    const text = clean(result.text);
    if (!text || /^nothing\b/i.test(text)) return null;
    return { text, model: result.model };
}

/// His own past runs at the same kilometre: elapsed and heart rate, from the
/// metrics rows the phone uploaded. Searched inside a window around this
/// run's clock so a 10 km query stays small.
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
                out.push(`${when}: reached ${km} km at ${fmtClock(best.t)}${best.hr ? `, HR ${Math.round(best.hr)}` : ""} (this run is ${Math.abs(delta)} s ${delta <= 0 ? "faster" : "slower"})`);
            }
            if (out.length >= 3) break;
        }
        return out;
    } catch {
        return [];
    }
}

/// His wall clock, Beijing unless the phone sent its own. Without it the model
/// guessed the time of day from words like "tonight" and called a 10 am run evening.
function localNow(a: AmbientInput | undefined): string {
    const clock = a?.localClock ?? new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: "Asia/Shanghai" }).format(new Date());
    const day = a?.weekday ?? new Intl.DateTimeFormat("en-GB", { weekday: "long", timeZone: "Asia/Shanghai" }).format(new Date());
    return `- his local time: ${day} ${clock}, ${daypart(clock)} (never call it any other part of the day)`;
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
    return finalizeSpoken(t.replace(/[*_#>`]/g, "").replace(/\u2014|\u2013/g, ",").replace(/\s+/g, " ").trim(), "home");
}
