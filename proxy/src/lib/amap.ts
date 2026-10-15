/// Local intel from 高德 (Amap) for Home Base: what is physically around the
/// runner right now and the district's official weather. Web-service key in
/// env.AMAP_KEY (wrangler secret). Amap speaks GCJ-02; the phone sends WGS-84,
/// so inputs are shifted first. Fails soft to null; cached per ~500 m / 15 min.

export interface AmapEnv {
    AMAP_KEY?: string;
}

export interface LocalIntel {
    district?: string;
    weather?: string;        // "晴 21°C, 湿度 35%, 西南风 ≤3" rendered in English below
    tonight?: string;        // forecast line for tonight
    nearby: { name: string; type: string; meters: number }[];
}

const memo = new Map<string, { at: number; data: LocalIntel | null }>();
const TTL = 15 * 60_000;

export async function fetchLocalIntel(lat: number, lon: number, env: AmapEnv): Promise<LocalIntel | null> {
    if (!env.AMAP_KEY) return null;
    const key = `${lat.toFixed(3)},${lon.toFixed(3)}`;
    const hit = memo.get(key);
    if (hit && Date.now() - hit.at < TTL) return hit.data;
    let data: LocalIntel | null = null;
    try {
        data = await resolve(lat, lon, env.AMAP_KEY);
    } catch {
        data = null;
    }
    memo.set(key, { at: Date.now(), data });
    return data;
}

async function resolve(lat: number, lon: number, apiKey: string): Promise<LocalIntel | null> {
    const [glat, glon] = wgsToGcj(lat, lon);
    const loc = `${glon.toFixed(6)},${glat.toFixed(6)}`;
    const [regeo, around] = await Promise.all([
        getJSON(`https://restapi.amap.com/v3/geocode/regeo?key=${apiKey}&location=${loc}&extensions=base`),
        // Parks, scenic spots, sports venues, transit: the things a runner passes.
        getJSON(`https://restapi.amap.com/v3/place/around?key=${apiKey}&location=${loc}&radius=350&types=110100|110200|080100|080300|150500|060100|050000&offset=12&page=1&extensions=base`),
    ]);
    const out: LocalIntel = { nearby: [] };
    const ac = regeo?.regeocode?.addressComponent;
    const adcode: string | undefined = ac?.adcode;
    if (ac) out.district = [ac.district, typeof ac.township === "string" ? ac.township : ""].filter(Boolean).join(" ");
    if (Array.isArray(around?.pois)) {
        for (const p of around.pois) {
            const meters = Number(p.distance);
            if (!p.name || !Number.isFinite(meters)) continue;
            out.nearby.push({ name: String(p.name), type: String(p.type || "").split(";").pop() || "", meters });
            if (out.nearby.length >= 8) break;
        }
    }
    if (adcode) {
        const wx = await getJSON(`https://restapi.amap.com/v3/weather/weatherInfo?key=${apiKey}&city=${adcode}&extensions=all`);
        const live = await getJSON(`https://restapi.amap.com/v3/weather/weatherInfo?key=${apiKey}&city=${adcode}&extensions=base`);
        const l = live?.lives?.[0];
        if (l) out.weather = `${sky(l.weather)} ${l.temperature}°C, humidity ${l.humidity}%, ${wind(l.winddirection)} wind ${String(l.windpower).replace("≤", "up to ")} (Amap, ${String(l.reporttime).slice(11, 16)})`;
        const cast = wx?.forecasts?.[0]?.casts?.[0];
        if (cast) out.tonight = `tonight ${sky(cast.nightweather)}, low ${cast.nighttemp}°C, ${wind(cast.nightwind)} wind ${cast.nightpower}`;
    }
    return out;
}

export function formatLocalIntel(i: LocalIntel | null): string | null {
    if (!i) return null;
    const bits: string[] = [];
    if (i.district) bits.push(`- district: ${i.district}`);
    if (i.weather) bits.push(`- weather: ${i.weather}`);
    if (i.tonight) bits.push(`- forecast: ${i.tonight}`);
    if (i.nearby.length) bits.push(`- within 350 m: ${i.nearby.map((n) => `${n.name} (${n.type}, ${n.meters} m)`).join("; ")}`);
    return bits.length ? bits.join("\n") : null;
}

async function getJSON(url: string): Promise<any | null> {
    try {
        const r = await fetch(url, { signal: AbortSignal.timeout(2500), cf: { cacheTtl: 600, cacheEverything: true } } as RequestInit);
        if (!r.ok) return null;
        const j = await r.json<any>();
        return j && (j.status === "1" || j.status === 1) ? j : null;
    } catch {
        return null;
    }
}

function sky(zh: unknown): string {
    const s = String(zh ?? "");
    const map: Record<string, string> = { 晴: "clear", 多云: "cloudy", 阴: "overcast", 小雨: "light rain", 中雨: "rain", 大雨: "heavy rain", 雷阵雨: "thunderstorms", 雾: "fog", 霾: "haze", 小雪: "light snow", 雪: "snow", 阵雨: "showers" };
    for (const k of Object.keys(map)) if (s.includes(k)) return map[k]!;
    return s || "unknown";
}
function wind(zh: unknown): string {
    const s = String(zh ?? "");
    const map: Record<string, string> = { 东北: "northeast", 东南: "southeast", 西北: "northwest", 西南: "southwest", 东: "east", 南: "south", 西: "west", 北: "north", 无风向: "calm" };
    for (const k of Object.keys(map)) if (s.includes(k)) return map[k]!;
    return s || "variable";
}

// WGS-84 → GCJ-02 (the standard public transform; sub-metre agreement with
// the usual implementations, more than enough for a 350 m POI search).
function wgsToGcj(lat: number, lon: number): [number, number] {
    const a = 6378245.0, ee = 0.00669342162296594323;
    const dLat0 = transformLat(lon - 105.0, lat - 35.0);
    const dLon0 = transformLon(lon - 105.0, lat - 35.0);
    const radLat = (lat / 180.0) * Math.PI;
    let magic = Math.sin(radLat);
    magic = 1 - ee * magic * magic;
    const sqrtMagic = Math.sqrt(magic);
    const dLat = (dLat0 * 180.0) / (((a * (1 - ee)) / (magic * sqrtMagic)) * Math.PI);
    const dLon = (dLon0 * 180.0) / ((a / sqrtMagic) * Math.cos(radLat) * Math.PI);
    return [lat + dLat, lon + dLon];
}
function transformLat(x: number, y: number): number {
    let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
    ret += ((20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0) / 3.0;
    ret += ((20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin((y / 3.0) * Math.PI)) * 2.0) / 3.0;
    ret += ((160.0 * Math.sin((y / 12.0) * Math.PI) + 320 * Math.sin((y * Math.PI) / 30.0)) * 2.0) / 3.0;
    return ret;
}
function transformLon(x: number, y: number): number {
    let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
    ret += ((20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0) / 3.0;
    ret += ((20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin((x / 3.0) * Math.PI)) * 2.0) / 3.0;
    ret += ((150.0 * Math.sin((x / 12.0) * Math.PI) + 300.0 * Math.sin((x / 30.0) * Math.PI)) * 2.0) / 3.0;
    return ret;
}
