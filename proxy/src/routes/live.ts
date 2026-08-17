/// Live in-run channel — the "coach's coach". When the runner ticks "Share live
/// running data back home" for a REAL run, the app streams events here and polls
/// for a line the agent ("home") pushes back. Two auth scopes:
///   * device (header `X-AARC-Device` == DEVICE_TOKEN): the app — start, events,
///     end, and GET inject (dequeue a line to play).
///   * admin  (header `X-AARC-Admin`  == LIVE_ADMIN_TOKEN): the agent — status
///     (read the live feed) and POST inject (push a line).
/// Test runs are rejected at /live/start — real runs only.

import { venueKey } from "../lib/venueProfile";

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

    // POST /live/venue { venue, profile } — ADMIN stores what a venue is like
    if (request.method === "POST" && p === "/live/venue") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{ venue?: string; profile?: string }>();
        const venue = (b.venue ?? "").trim();
        const profile = (b.profile ?? "").trim();
        if (!venue || !profile) return json({ ok: false, error: "venue + profile required" }, 400);
        await env.DB.prepare(
            "INSERT INTO venue_profile (venue_key, venue, profile, updated_at) VALUES (?,?,?,datetime('now')) " +
            "ON CONFLICT(venue_key) DO UPDATE SET venue=excluded.venue, profile=excluded.profile, updated_at=excluded.updated_at",
        ).bind(venueKey(venue), venue, profile.slice(0, 4000)).run();
        return json({ ok: true, venueKey: venueKey(venue) });
    }

    // GET /live/venue[?venue=] — ADMIN reads stored profiles
    if (request.method === "GET" && p === "/live/venue") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const want = url.searchParams.get("venue");
        if (want) {
            const row = await env.DB.prepare("SELECT venue, profile, updated_at FROM venue_profile WHERE venue_key = ?")
                .bind(venueKey(want)).first();
            return json({ ok: true, item: row ?? null });
        }
        const res = await env.DB.prepare("SELECT venue, substr(profile,1,90) preview, updated_at FROM venue_profile ORDER BY updated_at DESC LIMIT 30").all();
        return json({ ok: true, items: res.results ?? [] });
    }

    // ---- HOME BASE BRIEFING — the agent feeds real-world intel to BOTH voices.
    // Unlike /live/inject (one spoken line, one run), a briefing item is
    // MATERIAL: it rides along in every Ricky/Jessica prompt until removed.

    // POST /live/briefing { items:[{kind,text}] | text, kind, ttlHours, replace }
    if (request.method === "POST" && p === "/live/briefing") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<{
            items?: { kind?: string; text?: string }[];
            text?: string;
            kind?: string;
            ttlHours?: number;
            replace?: boolean;
        }>();
        const raw = b.items ?? (b.text ? [{ kind: b.kind, text: b.text }] : []);
        const items = raw
            .map((i) => ({ kind: (i.kind ?? "buzz").slice(0, 24), text: (i.text ?? "").trim().slice(0, 400) }))
            .filter((i) => i.text.length > 0);
        if (items.length === 0) return json({ ok: false, error: "items[] or text required" }, 400);
        // Briefings go stale fast — default 18h, so "today's buzz" can't be
        // read out tomorrow as if it were fresh.
        const ttl = b.ttlHours ?? 18;
        const expires = new Date(Date.now() + ttl * 3600_000).toISOString();
        const stmts = [];
        if (b.replace) stmts.push(env.DB.prepare("DELETE FROM home_briefing"));
        for (const i of items) {
            stmts.push(
                env.DB.prepare("INSERT INTO home_briefing (kind, text, expires_at) VALUES (?, ?, ?)")
                    .bind(i.kind, i.text, expires),
            );
        }
        await env.DB.batch(stmts);
        return json({ ok: true, stored: items.length, expiresAt: expires, replaced: !!b.replace });
    }

    // GET /live/briefing — ADMIN reads what the voices are currently being fed
    if (request.method === "GET" && p === "/live/briefing") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const res = await env.DB
            .prepare("SELECT id, kind, text, created_at, expires_at FROM home_briefing ORDER BY id DESC LIMIT 20")
            .all();
        const rows = (res.results ?? []) as { expires_at: string | null }[];
        const live = rows.filter((r) => !r.expires_at || r.expires_at > now).length;
        return json({ ok: true, live, items: res.results ?? [] });
    }

    // DELETE /live/briefing[?id=] — clear one item, or the whole board
    if (request.method === "DELETE" && p === "/live/briefing") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const id = url.searchParams.get("id");
        if (id) {
            await env.DB.prepare("DELETE FROM home_briefing WHERE id = ?").bind(Number(id)).run();
        } else {
            await env.DB.prepare("DELETE FROM home_briefing").run();
        }
        return json({ ok: true, cleared: id ?? "all" });
    }

    return json({ ok: false, error: "not found" }, 404);
}
