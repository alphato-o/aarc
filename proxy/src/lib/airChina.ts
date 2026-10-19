/// Station-measured air quality for mainland China from CNEMC, the national
/// real-time publishing platform (中国环境监测总站). Keyless, valid TLS, hourly.
///
/// Why not Open-Meteo here: its air-quality feed is the CAMS global MODEL, not
/// measurements. Run 2CC6D9EA (13 Oct 2026, Chaoyang, crystal-clear night):
/// the model said PM2.5 194 µg/m³ / US AQI 155 while the station 2.6 km away
/// and the runner's watch said ~25. Model output in Beijing is routinely off by
/// a whole category, which poisons every line the coaches build on it.
///
/// Two feeds: the nationwide city list (338 cities with centroids) picks the
/// nearest city, then that city's station list picks the nearest station.
/// CNEMC refuses foreign IPs, so the Worker never calls it: a launchd job on
/// the Beijing Mac mini (private/air-cn-push.sh) fetches both feeds every ten
/// minutes and POSTs them to /air-cn/push, which parks them in D1 (air_cn).
/// Direct fetch is kept only for local dev inside China. Everything fails soft
/// to `null` so the caller can fall back to the model.

export interface StationAir {
    aqi: number;            // China-scale AQI (HJ 633-2012): the number Apple Weather / the watch shows here
    quality: string;        // English rendering of the station's 质量 band
    pm25?: number;
    pm10?: number;
    ozone?: number;
    pollutant?: string;     // "PM2.5" | "PM10" | "ozone" | "NO2" | "SO2" | "CO"
    usAqi?: number;         // US EPA AQI computed from PM2.5 (2024 breakpoints), for the stricter read
    usCategory?: string;
    station: string;
    stationKm: number;
    city: string;
    asOf: string;           // "HH:MM" Beijing time of the reading
}

const BASE = "https://air.cnemc.cn:18007/CityData";
const memo = new Map<string, { at: number; data: StationAir | null }>();
const TTL = 10 * 60_000;
const NULL_TTL = 60_000;   // a miss is retried soon: the mini may push any minute

export interface AirCnEnv {
    DB?: D1Database;
}

interface Feeds {
    cities: any[];
    stationsByCity: Map<string, any[]>;
}

/// Rough mainland box; the distance caps below do the real gating.
export function inChinaBox(lat: number, lon: number): boolean {
    return lat >= 18 && lat <= 54 && lon >= 73 && lon <= 135;
}

export async function fetchChinaStationAir(lat: number, lon: number, env?: AirCnEnv): Promise<StationAir | null> {
    const key = `${lat.toFixed(2)},${lon.toFixed(2)}`;
    const hit = memo.get(key);
    if (hit && Date.now() - hit.at < (hit.data ? TTL : NULL_TTL)) return hit.data;
    let data: StationAir | null = null;
    try {
        // The US gateway has no D1, so it never saw the pushed stations and
        // read the forecast model instead (19 Oct: "AQI 166" against a measured 19).
        // Ask the Worker, which holds them.
        if (!env?.DB) {
            data = await fromWorker(lat, lon);
            memo.set(key, { at: Date.now(), data });
            return data;
        }
        const feeds = (await loadPushed(env)) ?? (await loadDirect(lat, lon));
        data = feeds ? resolve(lat, lon, feeds) : null;
    } catch {
        data = null;
    }
    memo.set(key, { at: Date.now(), data });
    return data;
}

async function fromWorker(lat: number, lon: number): Promise<StationAir | null> {
    const r = await fetch(`https://api.aarun.club/air-cn?lat=${lat}&lon=${lon}`, { signal: AbortSignal.timeout(5000) });
    if (!r.ok) return null;
    const body = (await r.json()) as { air?: StationAir | null };
    return body.air ?? null;
}

/// Store what the in-China pusher sent. `stations` is keyed by the CNEMC city
/// name (e.g. "北京市"); each list is slimmed to the fields `resolve` reads.
export async function storePushed(env: AirCnEnv, body: { cities?: any[]; stations?: Record<string, any[]> }): Promise<number> {
    if (!env.DB) return 0;
    const now = new Date().toISOString();
    const stmts: D1PreparedStatement[] = [];
    const up = env.DB.prepare("INSERT INTO air_cn (id, payload, fetched_at) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at");
    if (Array.isArray(body.cities) && body.cities.length) stmts.push(up.bind("cities", JSON.stringify(body.cities.map(slim)), now));
    for (const [city, list] of Object.entries(body.stations ?? {})) {
        if (Array.isArray(list) && list.length) stmts.push(up.bind(`stations:${city}`, JSON.stringify(list.map(slim)), now));
    }
    if (stmts.length) await env.DB.batch(stmts);
    return stmts.length;
}

const KEEP = ["Area", "PositionName", "Latitude", "Longitude", "AQI", "PM2_5", "PM10", "O3", "Quality", "PrimaryPollutant", "TimePoint"];
function slim(row: any): any {
    const o: any = {};
    for (const k of KEEP) if (row?.[k] != null) o[k] = row[k];
    return o;
}

async function loadPushed(env?: AirCnEnv): Promise<Feeds | null> {
    if (!env?.DB) return null;
    const rows = await env.DB.prepare("SELECT id, payload, fetched_at FROM air_cn").all<{ id: string; payload: string; fetched_at: string }>();
    const feeds: Feeds = { cities: [], stationsByCity: new Map() };
    for (const r of rows.results ?? []) {
        if (Date.now() - Date.parse(r.fetched_at) > 3 * 3600_000) continue;   // pusher down: fall through to the model
        let v: any;
        try { v = JSON.parse(r.payload); } catch { continue; }
        if (!Array.isArray(v)) continue;
        if (r.id === "cities") feeds.cities = v;
        else if (r.id.startsWith("stations:")) feeds.stationsByCity.set(r.id.slice("stations:".length), v);
    }
    return feeds.cities.length ? feeds : null;
}

// Only works from inside China; harmless elsewhere (times out to null).
async function loadDirect(lat: number, lon: number): Promise<Feeds | null> {
    const cities = await getJSON(`${BASE}/GetAllCityRealTimeAQIModels`);
    if (!Array.isArray(cities) || !cities.length) return null;
    const feeds: Feeds = { cities, stationsByCity: new Map() };
    const near = nearestCity(lat, lon, cities);
    if (near.city) {
        const st = await getJSON(`${BASE}/GetAQIDataPublishLive?cityName=${encodeURIComponent(String(near.city.Area))}`);
        if (Array.isArray(st)) feeds.stationsByCity.set(String(near.city.Area), st);
    }
    return feeds;
}

function nearestCity(lat: number, lon: number, cities: any[]): { city: any; km: number } {
    let city: any = null, best = Infinity;
    for (const c of cities) {
        const d = km(lat, lon, Number(c.Latitude), Number(c.Longitude));
        if (Number.isFinite(d) && d < best) { best = d; city = c; }
    }
    return { city, km: best };
}

function resolve(lat: number, lon: number, feeds: Feeds): StationAir | null {
    const { city, km: cityKm } = nearestCity(lat, lon, feeds.cities);
    // Nearest listed city 120 km away means we're not somewhere CNEMC covers.
    if (!city || cityKm > 120) return null;

    const stations = feeds.stationsByCity.get(String(city.Area)) ?? [];
    let best: any = null, bestKm = Infinity;
    for (const s of stations) {
        if (!Number.isFinite(Number(s.AQI))) continue;  // "—" when a station is down
        const d = km(lat, lon, Number(s.Latitude), Number(s.Longitude));
        if (Number.isFinite(d) && d < bestKm) { bestKm = d; best = s; }
    }
    // No usable station within 40 km: the city average is still measured
    // (not modelled), so use it rather than drop to the model.
    const src = best && bestKm <= 40 ? best : city;
    const srcKm = best && bestKm <= 40 ? bestKm : cityKm;
    if (!Number.isFinite(Number(src.AQI))) return null;
    if (isStale(String(src.TimePoint ?? ""))) return null;
    const pm25 = num(src.PM2_5);
    const out: StationAir = {
        aqi: Number(src.AQI),
        quality: qualityEn(String(src.Quality ?? "")),
        pm25,
        pm10: num(src.PM10),
        ozone: num(src.O3),
        pollutant: pollutantEn(String(src.PrimaryPollutant ?? "")),
        station: src === city ? `${city.Area} (city average)` : String(src.PositionName),
        stationKm: Math.round(srcKm * 10) / 10,
        city: String(city.Area),
        asOf: clockOf(String(src.TimePoint ?? "")) ?? "",
    };
    if (pm25 != null) {
        out.usAqi = usAqiFromPm25(pm25);
        out.usCategory = usCategory(out.usAqi);
    }
    return out;
}

async function getJSON(url: string): Promise<any | null> {
    try {
        const r = await fetch(url, {
            signal: AbortSignal.timeout(3000),
            cf: { cacheTtl: 900, cacheEverything: true },
        } as RequestInit);
        if (!r.ok) return null;
        return await r.json();
    } catch {
        return null;
    }
}

function km(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const R = 6371, toR = Math.PI / 180;
    const dLat = (lat2 - lat1) * toR, dLon = (lon2 - lon1) * toR;
    const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * toR) * Math.cos(lat2 * toR) * Math.sin(dLon / 2) ** 2;
    return 2 * R * Math.asin(Math.sqrt(a));
}

function num(v: unknown): number | undefined {
    const n = Number(v);
    return Number.isFinite(n) ? Math.round(n) : undefined;
}

function clockOf(tp: string): string | undefined {
    const m = /T(\d{2}:\d{2})/.exec(tp);
    return m ? m[1] : undefined;
}

// TimePoint is Beijing local time with no zone suffix; a reading older than
// 3 h means the platform is lagging and the model is the lesser evil.
function isStale(tp: string): boolean {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(tp);
    if (!m) return true;
    const t = Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]! - 8, +m[5]!);
    return Date.now() - t > 3 * 3600_000;
}

function qualityEn(q: string): string {
    if (q.includes("优")) return "Excellent";
    if (q.includes("良")) return "Good";
    if (q.includes("轻度")) return "Lightly polluted";
    if (q.includes("中度")) return "Moderately polluted";
    if (q.includes("重度")) return "Heavily polluted";
    if (q.includes("严重")) return "Severely polluted";
    return q || "unknown";
}

function pollutantEn(p: string): string | undefined {
    if (!p || p === "-" || p === "—") return undefined;
    if (p.includes("PM2.5") || p.includes("细颗粒")) return "PM2.5";
    if (p.includes("PM10") || p.includes("颗粒")) return "PM10";
    if (p.includes("臭氧") || p.includes("O3")) return "ozone";
    if (p.includes("二氧化氮") || p.includes("NO2")) return "NO2";
    if (p.includes("二氧化硫") || p.includes("SO2")) return "SO2";
    if (p.includes("一氧化碳") || p.includes("CO")) return "CO";
    return undefined;
}

// US EPA PM2.5 breakpoints (May 2024 revision), 24-h scale applied to the
// hourly value: the same shortcut every consumer app takes.
function usAqiFromPm25(c: number): number {
    const bp: [number, number, number, number][] = [
        [0, 9.0, 0, 50], [9.1, 35.4, 51, 100], [35.5, 55.4, 101, 150],
        [55.5, 125.4, 151, 200], [125.5, 225.4, 201, 300], [225.5, 325.4, 301, 500],
    ];
    const x = Math.min(c, 325.4);
    for (const [cl, ch, il, ih] of bp) {
        if (x <= ch) return Math.round(((ih - il) / (ch - cl)) * (Math.max(x, cl) - cl) + il);
    }
    return 500;
}

function usCategory(aqi: number): string {
    if (aqi <= 50) return "Good";
    if (aqi <= 100) return "Moderate";
    if (aqi <= 150) return "Unhealthy for sensitive groups";
    if (aqi <= 200) return "Unhealthy";
    if (aqi <= 300) return "Very unhealthy";
    return "Hazardous";
}
