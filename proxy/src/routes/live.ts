/// Live in-run channel — the "coach's coach". When the runner ticks "Share live
/// running data back home" for a REAL run, the app streams events here and polls
/// for a line the agent ("home") pushes back. Two auth scopes:
///   * device (header `X-AARC-Device` == DEVICE_TOKEN): the app — start, events,
///     end, and GET inject (dequeue a line to play).
///   * admin  (header `X-AARC-Admin`  == LIVE_ADMIN_TOKEN): the agent — status
///     (read the live feed) and POST inject (push a line).
/// Test runs are rejected at /live/start — real runs only.

export interface LiveEnv {
    DB: D1Database;
    LIVE_DEVICE_TOKEN?: string;
    LIVE_ADMIN_TOKEN?: string;
}

const MAX_RECENT = 200;
const STALE_MS = 3 * 60 * 1000; // no events for 3 min ⇒ the run is no longer live

function isDevice(req: Request, env: LiveEnv): boolean {
    return !!env.LIVE_DEVICE_TOKEN && req.headers.get("x-aarc-device") === env.LIVE_DEVICE_TOKEN;
}
function isAdmin(req: Request, env: LiveEnv): boolean {
    return !!env.LIVE_ADMIN_TOKEN && req.headers.get("x-aarc-admin") === env.LIVE_ADMIN_TOKEN;
}
function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

export async function liveHandler(request: Request, url: URL, env: LiveEnv): Promise<Response> {
    const p = url.pathname;
    const now = new Date().toISOString();

    // POST /live/start { runId, isTest, startedAt } — device
    if (request.method === "POST" && p === "/live/start") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ runId?: string; isTest?: boolean; startedAt?: string }>();
        if (!b.runId) return json({ ok: false, error: "runId required" }, 400);
        if (b.isTest) return json({ ok: true, ignored: "test run" }); // REAL runs only
        // New live run supersedes any prior one.
        await env.DB.batch([
            env.DB.prepare("UPDATE live_run SET ended_at = ? WHERE ended_at IS NULL").bind(now),
            env.DB
                .prepare("INSERT OR REPLACE INTO live_run (run_id, started_at, last_event_at, ended_at, recent_events) VALUES (?, ?, ?, NULL, '[]')")
                .bind(b.runId, b.startedAt ?? now, now),
        ]);
        return json({ ok: true });
    }

    // POST /live/events { runId, events:[...] } — device
    if (request.method === "POST" && p === "/live/events") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ runId?: string; events?: unknown[] }>();
        if (!b.runId || !Array.isArray(b.events)) return json({ ok: false, error: "runId + events required" }, 400);
        const row = await env.DB.prepare("SELECT recent_events FROM live_run WHERE run_id = ?").bind(b.runId).first<{ recent_events: string }>();
        if (!row) return json({ ok: false, error: "no such live run" }, 404);
        let recent: unknown[] = [];
        try { recent = JSON.parse(row.recent_events); } catch { /* reset */ }
        recent = recent.concat(b.events).slice(-MAX_RECENT);
        await env.DB.prepare("UPDATE live_run SET recent_events = ?, last_event_at = ? WHERE run_id = ?")
            .bind(JSON.stringify(recent), now, b.runId).run();
        return json({ ok: true, count: recent.length });
    }

    // POST /live/end { runId } — device
    if (request.method === "POST" && p === "/live/end") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ runId?: string }>();
        if (!b.runId) return json({ ok: false, error: "runId required" }, 400);
        await env.DB.prepare("UPDATE live_run SET ended_at = ? WHERE run_id = ? AND ended_at IS NULL").bind(now, b.runId).run();
        return json({ ok: true });
    }

    // GET /live/inject?runId= — device dequeues the next line to play
    if (request.method === "GET" && p === "/live/inject") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const runId = url.searchParams.get("runId");
        if (!runId) return json({ ok: false, error: "runId required" }, 400);
        const line = await env.DB
            .prepare("SELECT id, text, voice_id FROM live_inject WHERE run_id = ? AND consumed_at IS NULL ORDER BY id ASC LIMIT 1")
            .bind(runId).first<{ id: number; text: string; voice_id: string }>();
        if (!line) return json({ ok: true, line: null });
        await env.DB.prepare("UPDATE live_inject SET consumed_at = ? WHERE id = ?").bind(now, line.id).run();
        return json({ ok: true, line: { text: line.text, voiceId: line.voice_id } });
    }

    // GET /live/status — ADMIN reads the live feed
    if (request.method === "GET" && p === "/live/status") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const row = await env.DB
            .prepare("SELECT run_id, started_at, last_event_at, ended_at, recent_events FROM live_run WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1")
            .first<{ run_id: string; started_at: string; last_event_at: string | null; ended_at: string | null; recent_events: string }>();
        if (!row) return json({ ok: true, active: false });
        const ageMs = row.last_event_at ? Date.now() - new Date(row.last_event_at).getTime() : Infinity;
        const active = ageMs < STALE_MS;
        let events: unknown[] = [];
        try { events = JSON.parse(row.recent_events); } catch { /* */ }
        return json({
            ok: true, active, runId: row.run_id, startedAt: row.started_at,
            lastEventAt: row.last_event_at, staleSeconds: Math.round(ageMs / 1000),
            eventCount: events.length, recentEvents: events,
        });
    }

    // POST /live/inject { runId, text, voiceId } — ADMIN pushes a line
    if (request.method === "POST" && p === "/live/inject") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ runId?: string; text?: string; voiceId?: string }>();
        if (!b.runId || !b.text || !b.voiceId) return json({ ok: false, error: "runId + text + voiceId required" }, 400);
        await env.DB.prepare("INSERT INTO live_inject (run_id, text, voice_id) VALUES (?, ?, ?)").bind(b.runId, b.text, b.voiceId).run();
        return json({ ok: true });
    }

    return json({ ok: false, error: "not found" }, 404);
}
