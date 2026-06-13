/// Personal-troll bullets, stored server-side so they can be edited on the
/// dashboard (the iPhone textarea was impractical for a long list). The iOS
/// app pulls this at launch and caches it; the dashboard reads + writes it.
///
///   GET /api/personal-notes   → { ok, body, updatedAt }   (authed)
///   PUT /api/personal-notes   body {body}  → { ok, updatedAt }  (authed)

interface Env {
    DB: D1Database;
    DEVICE_TOKEN?: string;
}

const json = (data: unknown, init: ResponseInit = {}): Response =>
    new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });

function authorized(request: Request, env: Env): boolean {
    if (!env.DEVICE_TOKEN) return false;
    if (request.headers.get("x-aarc-device") === env.DEVICE_TOKEN) return true;
    const cookie = request.headers.get("cookie") ?? "";
    const m = cookie.match(/(?:^|;\s*)aarc_session=([^;]+)/);
    return m?.[1] === env.DEVICE_TOKEN;
}

export async function personalNotesGetHandler(request: Request, env: Env): Promise<Response> {
    if (!authorized(request, env)) return json({ ok: false, error: "unauthorized" }, { status: 401 });
    const row = await env.DB.prepare("SELECT body, updated_at FROM personal_notes WHERE id = 1")
        .first<{ body: string; updated_at: string }>();
    return json({ ok: true, body: row?.body ?? "", updatedAt: row?.updated_at ?? "" });
}

export async function personalNotesPutHandler(request: Request, env: Env): Promise<Response> {
    if (!authorized(request, env)) return json({ ok: false, error: "unauthorized" }, { status: 401 });
    let parsed: { body?: unknown };
    try { parsed = (await request.json()) as typeof parsed; }
    catch { return json({ ok: false, error: "bad_json" }, { status: 400 }); }
    const body = String(parsed.body ?? "");
    if (body.length > 20000) return json({ ok: false, error: "too_long" }, { status: 400 });
    const now = new Date().toISOString();
    await env.DB.prepare(
        "INSERT INTO personal_notes (id, body, updated_at) VALUES (1, ?, ?) " +
        "ON CONFLICT(id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at")
        .bind(body, now).run();
    return json({ ok: true, updatedAt: now });
}
