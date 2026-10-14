/// GET  /air-cn?lat&lon   nearest official CNEMC station reading (public data).
/// POST /air-cn/push      admin: the in-China pusher parks the CNEMC feeds here,
///                        because CNEMC refuses foreign IPs and the Worker is one.

import { fetchChinaStationAir, inChinaBox, storePushed, type AirCnEnv } from "../lib/airChina";

const json = (data: unknown, status = 200): Response =>
    new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

export async function airCnHandler(request: Request, env: AirCnEnv): Promise<Response> {
    const url = new URL(request.url);
    const lat = Number(url.searchParams.get("lat"));
    const lon = Number(url.searchParams.get("lon"));
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return json({ ok: false, error: "lat/lon required" }, 400);
    const air = inChinaBox(lat, lon) ? await fetchChinaStationAir(lat, lon, env) : null;
    return json({ ok: true, air });
}

export async function airCnPushHandler(request: Request, env: AirCnEnv): Promise<Response> {
    let body: any;
    try {
        body = await request.json();
    } catch {
        return json({ ok: false, error: "bad json" }, 400);
    }
    if (typeof body !== "object" || body === null) return json({ ok: false, error: "bad shape" }, 400);
    if (body.cities != null && !Array.isArray(body.cities)) return json({ ok: false, error: "cities must be an array" }, 400);
    if (body.stations != null && (typeof body.stations !== "object" || Array.isArray(body.stations))) return json({ ok: false, error: "stations must be an object" }, 400);
    const stored = await storePushed(env, body);
    return json({ ok: true, stored });
}
