/// /agent/* — the runner's direct line to the agent, mirrored in the app's
/// "Home Base terminal". Same two-token model as /live: the phone is the
/// device, the agent is the admin.
///
///   POST /agent/send    device  {text}            → append a user row
///   GET  /agent/thread  device  ?since=<id>        → rows after id (both roles)
///   POST /agent/reply   admin   {text}            → append an agent row
///   GET  /agent/inbox   admin                      → unseen user rows, marks them seen
export interface AgentEnv {
    DB: D1Database;
    LIVE_DEVICE_TOKEN?: string;
    LIVE_ADMIN_TOKEN?: string;
}

function isDevice(req: Request, env: AgentEnv): boolean {
    return !!env.LIVE_DEVICE_TOKEN && req.headers.get("x-aarc-device") === env.LIVE_DEVICE_TOKEN;
}
function isAdmin(req: Request, env: AgentEnv): boolean {
    return !!env.LIVE_ADMIN_TOKEN && req.headers.get("x-aarc-admin") === env.LIVE_ADMIN_TOKEN;
}
function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

export async function agentHandler(request: Request, url: URL, env: AgentEnv): Promise<Response> {
    const p = url.pathname;

    if (request.method === "POST" && p === "/agent/send") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ text?: string }>().catch(() => ({} as { text?: string }));
        const text = (b.text ?? "").trim().slice(0, 4000);
        if (!text) return json({ ok: false, error: "text required" }, 400);
        const r = await env.DB.prepare("INSERT INTO agent_thread (role, text) VALUES ('user', ?)").bind(text).run();
        return json({ ok: true, id: r.meta.last_row_id });
    }

    if (request.method === "GET" && p === "/agent/thread") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const since = Number(url.searchParams.get("since") ?? 0) || 0;
        const limit = Math.min(200, Number(url.searchParams.get("limit") ?? 100) || 100);
        const rows = since > 0
            ? await env.DB.prepare("SELECT id, role, text, created_at FROM agent_thread WHERE id > ? ORDER BY id ASC LIMIT ?").bind(since, limit).all()
            : await env.DB.prepare("SELECT id, role, text, created_at FROM (SELECT id, role, text, created_at FROM agent_thread ORDER BY id DESC LIMIT ?) ORDER BY id ASC").bind(limit).all();
        return json({ ok: true, messages: rows.results ?? [] });
    }

    if (request.method === "POST" && p === "/agent/reply") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ text?: string }>().catch(() => ({} as { text?: string }));
        const text = (b.text ?? "").trim().slice(0, 8000);
        if (!text) return json({ ok: false, error: "text required" }, 400);
        const r = await env.DB.prepare("INSERT INTO agent_thread (role, text) VALUES ('agent', ?)").bind(text).run();
        return json({ ok: true, id: r.meta.last_row_id });
    }

    if (request.method === "GET" && p === "/agent/inbox") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const rows = await env.DB.prepare("SELECT id, text, created_at FROM agent_thread WHERE role='user' AND seen_at IS NULL ORDER BY id ASC LIMIT 50").all();
        const items = rows.results ?? [];
        if (items.length) {
            await env.DB.prepare("UPDATE agent_thread SET seen_at = datetime('now') WHERE role='user' AND seen_at IS NULL").run();
        }
        return json({ ok: true, messages: items });
    }

    return json({ ok: false, error: "not found" }, 404);
}
