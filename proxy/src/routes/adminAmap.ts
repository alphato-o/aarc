/// GET /admin/amap/<amap path>?<query> — admin-only passthrough to Amap's web
/// service with the Worker's key attached. The agent uses it from the desk to
/// map race courses and research venues without the key ever leaving
/// Cloudflare. Admin token = LIVE_ADMIN_TOKEN (same as /live/status).

export interface AdminAmapEnv { AMAP_KEY?: string; LIVE_ADMIN_TOKEN?: string }

export async function adminAmapHandler(request: Request, url: URL, env: AdminAmapEnv): Promise<Response> {
    if (!env.LIVE_ADMIN_TOKEN || request.headers.get("x-aarc-admin") !== env.LIVE_ADMIN_TOKEN) {
        return new Response("forbidden", { status: 403 });
    }
    if (!env.AMAP_KEY) return new Response(JSON.stringify({ ok: false, error: "no AMAP_KEY" }), { status: 503 });
    const path = url.pathname.replace(/^\/admin\/amap\//, "");
    if (!/^v[3-5]\/[a-z0-9_/]+$/i.test(path)) return new Response("bad path", { status: 400 });
    const target = new URL(`https://restapi.amap.com/${path}`);
    url.searchParams.forEach((v, k) => { if (k !== "key") target.searchParams.set(k, v); });
    target.searchParams.set("key", env.AMAP_KEY);
    // Binary for the static map, JSON for everything else: pass the body through untouched.
    const r = await fetch(target.toString());
    return new Response(await r.arrayBuffer(), { status: r.status, headers: { "content-type": r.headers.get("content-type") ?? "application/json" } });
}
