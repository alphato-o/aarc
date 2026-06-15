/// Real-time ambient context for feedback generation — AARC's edge is
/// relevance, so we feed the coaches as much true, current detail as we can:
/// weather + "feels like" + wind + humidity, air quality (gold in China),
/// sunrise/sunset, and a couple of live news headlines (world + city).
///
/// All sourced SERVER-side from keyless APIs (Open-Meteo for weather/AQI,
/// Google-News RSS for headlines) so there are no keys to manage and no
/// China-reachability problem on the device. Cached per rounded-location +
/// hour (module memo + edge cacheTtl) so it costs ~one fetch/hour/location,
/// not one per line. Every piece fails soft — a dead feed just omits itself.

export interface AmbientInput {
    lat?: number;
    lon?: number;
    city?: string;
    venue?: string;       // treadmill venue guess from the phone
    localClock?: string;  // "18:42"
    weekday?: string;     // "Sunday"
    monthDay?: string;    // "15 June"
}

interface Resolved {
    tempC?: number;
    feelsC?: number;
    humidity?: number;
    windKmh?: number;
    conditions?: string;
    isDay?: boolean;
    sunrise?: string;
    sunset?: string;
    aqi?: number;          // European AQI — tracks the user's local weather app
    pm25?: number;         // PM2.5 µg/m³ — the concrete, standard-agnostic number
    aqiCategory?: string;
    pollutant?: string;
    worldNews?: string[];
    cityNews?: string[];
}

const memo = new Map<string, { at: number; data: Resolved }>();
const HOUR = 3600_000;

function wmo(code: number | undefined): string | undefined {
    if (code == null) return undefined;
    if (code === 0) return "clear";
    if (code <= 2) return "partly cloudy";
    if (code === 3) return "overcast";
    if (code <= 48) return "fog";
    if (code <= 57) return "drizzle";
    if (code <= 67) return "rain";
    if (code <= 77) return "snow";
    if (code <= 82) return "rain showers";
    if (code <= 86) return "snow showers";
    return "thunderstorm";
}

// US AQI category. The founder trusts the US standard (it doesn't soften a bad
// day the way European/PM-only readings do — its ozone weighting is the point).
function aqiCat(aqi: number | undefined): string | undefined {
    if (aqi == null) return undefined;
    if (aqi <= 50) return "Good";
    if (aqi <= 100) return "Moderate";
    if (aqi <= 150) return "Unhealthy for sensitive groups";
    if (aqi <= 200) return "Unhealthy";
    if (aqi <= 300) return "Very unhealthy";
    return "Hazardous";
}

async function getJSON(url: string): Promise<any | null> {
    try {
        const r = await fetch(url, {
            signal: AbortSignal.timeout(2500),  // never stall a line on a slow upstream
            cf: { cacheTtl: 1800, cacheEverything: true },
        } as RequestInit);
        if (!r.ok) return null;
        return await r.json();
    } catch {
        return null;
    }
}

// Top RSS <item> titles, keyless (Google News). Trims the " - Source" suffix.
async function rssTitles(url: string, n: number): Promise<string[]> {
    try {
        const r = await fetch(url, {
            headers: { "User-Agent": "Mozilla/5.0" },
            signal: AbortSignal.timeout(2500),
            cf: { cacheTtl: 1800, cacheEverything: true },
        } as RequestInit);
        if (!r.ok) return [];
        const xml = await r.text();
        const out: string[] = [];
        const re = /<item>[\s\S]*?<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?<\/title>/g;
        let m: RegExpExecArray | null;
        while ((m = re.exec(xml)) && out.length < n) {
            const t = (m[1] || "").replace(/\s+-\s+[^-]+$/, "").trim();
            if (t) out.push(t.slice(0, 140));
        }
        return out;
    } catch {
        return [];
    }
}

export async function fetchAmbient(input: AmbientInput): Promise<Resolved> {
    if (input.lat == null || input.lon == null) {
        // No location → still try city news only.
        return input.city ? { cityNews: await rssTitles(newsUrl(input.city), 2) } : {};
    }
    const lat = input.lat, lon = input.lon;
    const key = `${lat.toFixed(2)},${lon.toFixed(2)},${Math.floor(Date.now() / HOUR)}`;
    const hit = memo.get(key);
    if (hit && Date.now() - hit.at < HOUR) return hit.data;

    const wxURL =
        `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
        `&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day` +
        `&daily=sunrise,sunset&timezone=auto&forecast_days=1`;
    const aqURL =
        `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lon}` +
        `&current=european_aqi,us_aqi,pm2_5,pm10,ozone`;

    const [wx, aq, world, city] = await Promise.all([
        getJSON(wxURL),
        getJSON(aqURL),
        rssTitles("https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en", 2),
        input.city ? rssTitles(newsUrl(input.city), 2) : Promise.resolve([]),
    ]);

    const data: Resolved = {};
    if (wx?.current) {
        data.tempC = round(wx.current.temperature_2m);
        data.feelsC = round(wx.current.apparent_temperature);
        data.humidity = round(wx.current.relative_humidity_2m);
        data.windKmh = round(wx.current.wind_speed_10m);
        data.conditions = wmo(wx.current.weather_code);
        data.isDay = wx.current.is_day === 1;
    }
    if (wx?.daily?.sunrise?.[0]) data.sunrise = clockOf(wx.daily.sunrise[0]);
    if (wx?.daily?.sunset?.[0]) data.sunset = clockOf(wx.daily.sunset[0]);
    if (aq?.current) {
        // US AQI is the headline (founder's preference); PM2.5 µg/m³ rides
        // along as the concrete anchor.
        data.aqi = round(aq.current.us_aqi);
        data.pm25 = round(aq.current.pm2_5);
        data.aqiCategory = aqiCat(data.aqi);
        data.pollutant = dominant(aq.current);
    }
    if (world.length) data.worldNews = world;
    if (city.length) data.cityNews = city;

    memo.set(key, { at: Date.now(), data });
    return data;
}

function newsUrl(city: string): string {
    return `https://news.google.com/rss/search?q=${encodeURIComponent(city)}&hl=en-US&gl=US&ceid=US:en`;
}
function round(v: unknown): number | undefined {
    const n = Number(v);
    return Number.isFinite(n) ? Math.round(n) : undefined;
}
function clockOf(iso: string): string | undefined {
    const m = /T(\d{2}:\d{2})/.exec(iso);
    return m ? m[1] : undefined;
}
function dominant(cur: any): string | undefined {
    const pm25 = Number(cur.pm2_5), pm10 = Number(cur.pm10), o3 = Number(cur.ozone);
    const arr = [["PM2.5", pm25], ["PM10", pm10], ["ozone", o3]].filter((x) => Number.isFinite(x[1] as number));
    if (!arr.length) return undefined;
    arr.sort((a, b) => (b[1] as number) - (a[1] as number));
    return arr[0]![0] as string;
}

/// Render the ambient block into the prompt. `input` carries the client's
/// time/venue; `r` is the server-resolved weather/AQI/news.
export function pushAmbientBlock(lines: string[], input: AmbientInput | undefined, r: Resolved): void {
    if (!input && !Object.keys(r).length) return;
    const out: string[] = [];

    const when = [input?.weekday, input?.localClock].filter(Boolean).join(" ");
    const date = input?.monthDay;
    if (when || date) {
        out.push(`- now: ${[when, date && `(${date})`].filter(Boolean).join(" ")}${input?.localClock ? ` — ${daypart(input.localClock)}` : ""}`);
    }
    if (date && input?.city) {
        out.push(`- date+place: it's ${date} in ${input.city} — use the SEASON, weather, and any notable local timing (holidays, festivals, exam season, plum rain, smog season, etc.) for this place + date when it sharpens a line.`);
    }
    if (r.tempC != null) {
        const bits = [`${r.tempC}°C`];
        if (r.feelsC != null && Math.abs(r.feelsC - r.tempC) >= 2) bits.push(`feels ${r.feelsC}°`);
        if (r.conditions) bits.push(r.conditions);
        if (r.humidity != null) bits.push(`${r.humidity}% humidity`);
        if (r.windKmh != null && r.windKmh >= 12) bits.push(`${r.windKmh} km/h wind`);
        out.push(`- weather: ${bits.join(", ")}`);
    }
    if (r.aqi != null || r.pm25 != null) {
        const bits: string[] = [];
        if (r.aqi != null) bits.push(`US AQI ${r.aqi}${r.aqiCategory ? ` (${r.aqiCategory}${r.pollutant ? `, ${r.pollutant} dominant` : ""})` : ""}`);
        if (r.pm25 != null) bits.push(`PM2.5 ${r.pm25} µg/m³`);
        out.push(`- air quality: ${bits.join(", ")}`);
    }
    if (r.sunset || r.sunrise) {
        const light = r.isDay === false ? "it's dark out" : "daylight";
        out.push(`- daylight: ${light}${r.sunset ? `, sunset ${r.sunset}` : ""}${r.sunrise ? `, sunrise ${r.sunrise}` : ""}`);
    }
    if (input?.venue) {
        out.push(`- venue (treadmill — wild but likely guess): they're probably working out at ${input.venue}. You may tease the guess.`);
    }
    if (r.worldNews?.length) out.push(`- world headlines: ${r.worldNews.map((h) => `"${h}"`).join("; ")}`);
    if (r.cityNews?.length) out.push(`- ${input?.city || "local"} headlines: ${r.cityNews.map((h) => `"${h}"`).join("; ")}`);

    if (!out.length) return;
    lines.push("");
    lines.push("LIVE AMBIENT CONTEXT (real + current — this is AARC's whole point: be relevant. Weave AT MOST ONE fresh ambient detail into a line when it sharpens the joke; rotate which kind you use; NEVER recite this list or stack multiple facts):");
    lines.push(...out);
    lines.push("A passing, knowing reference (the smog, the heat, the headline, the hour) lands harder than generic abuse. Don't force it into every line.");
}

function daypart(clock: string): string {
    const h = parseInt(clock.slice(0, 2), 10);
    if (h >= 5 && h < 9) return "early morning";
    if (h >= 9 && h < 12) return "late morning";
    if (h >= 12 && h < 14) return "lunchtime";
    if (h >= 14 && h < 17) return "afternoon";
    if (h >= 17 && h < 19) return "rush hour";
    if (h >= 19 && h < 22) return "evening";
    return "late night";
}
