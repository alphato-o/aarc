/// /venue-search — typed venue search for the treadmill picker.
///
/// Founder, 2026-10-13: in a gym he will never visit again, Apple's
/// categories returned nothing right. He wants to type, and he wants it to
/// work in China. Google is unusable there; 高德 (Amap) is the native
/// answer. Key lives here, never in the app (architecture rule 3).
///
///   GET /venue-search?q=<text>&lat=&lon=&city=   device
///   → { ok, provider, results: [{ name, address, distanceM, lat, lon }] }
/// Without AMAP_KEY it answers 501 so the app falls back to Apple keyword
/// search rather than pretending.
export interface VenueSearchEnv {
    AMAP_KEY?: string;
    LIVE_DEVICE_TOKEN?: string;
}

function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

export async function venueSearchHandler(request: Request, url: URL, env: VenueSearchEnv): Promise<Response> {
    if (!env.LIVE_DEVICE_TOKEN || request.headers.get("x-aarc-device") !== env.LIVE_DEVICE_TOKEN) {
        return json({ ok: false, error: "unauthorized" }, 401);
    }
    const q = (url.searchParams.get("q") ?? "").trim().slice(0, 80);
    if (!q) return json({ ok: false, error: "q required" }, 400);
    if (!env.AMAP_KEY) return json({ ok: false, error: "no_provider" }, 501);

    const lat = url.searchParams.get("lat");
    const lon = url.searchParams.get("lon");
    const city = url.searchParams.get("city") ?? "";
    // Amap place text search (v3). GCJ-02 in and out; the app converts.
    const params = new URLSearchParams({
        key: env.AMAP_KEY, keywords: q, offset: "15", page: "1", extensions: "base",
        types: "", city, citylimit: city ? "true" : "false",
    });
    if (lat && lon) params.set("location", `${lon},${lat}`);
    const r = await fetch(`https://restapi.amap.com/v3/place/text?${params}`, { cf: { cacheTtl: 0 } } as RequestInit);
    if (!r.ok) return json({ ok: false, error: `amap ${r.status}` }, 502);
    const j = await r.json<{ status: string; info?: string; pois?: Array<{ name: string; address?: string | string[]; location?: string; distance?: string; type?: string }> }>();
    if (j.status !== "1") return json({ ok: false, error: `amap: ${j.info ?? "unknown"}` }, 502);
    const results = (j.pois ?? []).map((p) => {
        const [plon, plat] = (p.location ?? ",").split(",").map(Number);
        return {
            name: p.name,
            address: Array.isArray(p.address) ? p.address.join(" ") : (p.address ?? ""),
            type: p.type ?? "",
            distanceM: p.distance ? Number(p.distance) : null,
            lat: plat, lon: plon,
        };
    });
    return json({ ok: true, provider: "amap", results });
}
