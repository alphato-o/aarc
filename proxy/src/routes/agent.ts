/// /agent/* — the runner's direct line to the agent, mirrored in the app's
/// "Home Base terminal". Same two-token model as /live: the phone is the
/// device, the agent is the admin.
///
///   POST /agent/send    device  {text, source?, runId?, km?, elapsed?}
///                                                 → append a user row ("terminal" or "voice")
///   POST /agent/voice   device  audio/mp4 body, ?clientId=&runId=&km=&elapsed=
///                                                 → transcribe, append a voice row; idempotent
///                                                   on clientId so an offline resend never doubles
///   GET  /agent/thread  device  ?since=<id>        → rows after id (both roles)
///   POST /agent/reply   admin   {text, speak?, runId?, voiceId?}
///                                                 → append an agent row; speak:true also
///                                                   queues it as a live/inject line for the
///                                                   run (runId, else the run of the latest
///                                                   user row), so it is heard mid-run
///   GET  /agent/inbox   admin                      → unseen user rows, marks them seen
///
/// Voice rows come from the "Tell Control Room" Siri shortcut (founder,
/// 2026-10-17): long-press on the earbuds, dictate, done. They carry the run
/// id and the km so the agent knows where he was when he said it.
import { transcribe, tidy, VoiceNoteEnv } from "./voiceNote";

export interface AgentEnv extends VoiceNoteEnv {
    DB: D1Database;
    LIVE_DEVICE_TOKEN?: string;
    LIVE_ADMIN_TOKEN?: string;
}

const CLIENT_ID_RE = /^[A-Za-z0-9-]{8,64}$/;
const MAX_TALKBACK_BYTES = 8 * 1024 * 1024;

function isDevice(req: Request, env: AgentEnv): boolean {
    return !!env.LIVE_DEVICE_TOKEN && req.headers.get("x-aarc-device") === env.LIVE_DEVICE_TOKEN;
}
function isAdmin(req: Request, env: AgentEnv): boolean {
    return !!env.LIVE_ADMIN_TOKEN && req.headers.get("x-aarc-admin") === env.LIVE_ADMIN_TOKEN;
}
interface SendBody { text?: string; source?: string; runId?: string; km?: number; elapsed?: number }
interface ReplyBody { text?: string; speak?: boolean; runId?: string; voiceId?: string }

/// Home Base's voice (Kristen). Same id the phone uses for its local lines.
const HOME_VOICE_ID = "Awx8TeMHHpDzbm42nIB6";

/// The run his LATEST line was said in, if it was recent enough to still be
/// going. A quiet run (sharing off) has no live_run row, so the thread is the
/// only place the phone tells us which run it is polling for. The latest row
/// decides: a line sent with no run means he is not running, and an older
/// run id must not catch the answer (a test run did, 17 Oct).
async function latestRunId(env: AgentEnv): Promise<string | null> {
    const row = await env.DB
        .prepare("SELECT run_id FROM agent_thread WHERE role='user' AND created_at > datetime('now', '-7 hours') ORDER BY id DESC LIMIT 1")
        .first<{ run_id: string | null }>();
    return row?.run_id ?? null;
}

function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

export async function agentHandler(request: Request, url: URL, env: AgentEnv): Promise<Response> {
    const p = url.pathname;

    if (request.method === "POST" && p === "/agent/send") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<SendBody>().catch(() => ({} as SendBody));
        const text = (b.text ?? "").trim().slice(0, 4000);
        if (!text) return json({ ok: false, error: "text required" }, 400);
        const source = b.source === "voice" ? "voice" : "terminal";
        const runId = typeof b.runId === "string" && b.runId.length <= 64 ? b.runId : null;
        const meta: Record<string, unknown> = {};
        if (typeof b.km === "number" && isFinite(b.km)) meta.km = Math.round(b.km * 100) / 100;
        if (typeof b.elapsed === "number" && isFinite(b.elapsed)) meta.elapsed = Math.round(b.elapsed);
        const r = await env.DB
            .prepare("INSERT INTO agent_thread (role, text, source, run_id, meta) VALUES ('user', ?, ?, ?, ?)")
            .bind(text, source, runId, Object.keys(meta).length ? JSON.stringify(meta) : null).run();
        return json({ ok: true, id: r.meta.last_row_id });
    }

    // Talk-back recorded by the app (founder, 2026-10-17: Siri's dictation cut
    // him off mid-sentence; out of breath he needs long pauses). He decides
    // when it ends; we transcribe with the voice-note chain.
    if (request.method === "POST" && p === "/agent/voice") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const clientId = url.searchParams.get("clientId") ?? "";
        if (!CLIENT_ID_RE.test(clientId)) return json({ ok: false, error: "invalid clientId" }, 400);
        const existing = await env.DB
            .prepare("SELECT id, text FROM agent_thread WHERE role='user' AND json_extract(meta, '$.clientId') = ? LIMIT 1")
            .bind(clientId).first<{ id: number; text: string }>();
        if (existing) return json({ ok: true, id: existing.id, text: existing.text, duplicate: true });

        const audio = await request.arrayBuffer();
        if (audio.byteLength === 0) return json({ ok: false, error: "empty body" }, 400);
        if (audio.byteLength > MAX_TALKBACK_BYTES) return json({ ok: false, error: "audio too large" }, 413);
        if (env.VOICES) {
            await env.VOICES.put(`talkback/${clientId}.m4a`, audio, { httpMetadata: { contentType: "audio/mp4" } });
        }
        const runIdRaw = url.searchParams.get("runId");
        const runId = runIdRaw && CLIENT_ID_RE.test(runIdRaw) ? runIdRaw : null;
        const km = Number(url.searchParams.get("km"));
        const elapsed = Number(url.searchParams.get("elapsed"));
        const durationS = Number(url.searchParams.get("duration") ?? "0");
        let text: string;
        try {
            const t = await transcribe(audio, env, Number.isFinite(durationS) ? durationS : 0);
            text = (await tidy(t.text, env)).trim();
        } catch (e) {
            // 502 so the phone keeps the audio and retries.
            return json({ ok: false, error: `transcription failed: ${e instanceof Error ? e.message : String(e)}`.slice(0, 300) }, 502);
        }
        if (!text) text = "[nothing audible]";
        const meta: Record<string, unknown> = { clientId, recorded: true };
        if (url.searchParams.has("km") && Number.isFinite(km)) meta.km = Math.round(km * 100) / 100;
        if (url.searchParams.has("elapsed") && Number.isFinite(elapsed)) meta.elapsed = Math.round(elapsed);
        if (Number.isFinite(durationS) && durationS > 0) meta.duration = Math.round(durationS);
        const r = await env.DB
            .prepare("INSERT INTO agent_thread (role, text, source, run_id, meta) VALUES ('user', ?, 'voice', ?, ?)")
            .bind(text.slice(0, 4000), runId, JSON.stringify(meta)).run();
        return json({ ok: true, id: r.meta.last_row_id, text });
    }

    if (request.method === "GET" && p === "/agent/thread") {
        if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const since = Number(url.searchParams.get("since") ?? 0) || 0;
        const limit = Math.min(200, Number(url.searchParams.get("limit") ?? 100) || 100);
        const rows = since > 0
            ? await env.DB.prepare("SELECT id, role, text, source, created_at FROM agent_thread WHERE id > ? ORDER BY id ASC LIMIT ?").bind(since, limit).all()
            : await env.DB.prepare("SELECT id, role, text, source, created_at FROM (SELECT id, role, text, source, created_at FROM agent_thread ORDER BY id DESC LIMIT ?) ORDER BY id ASC").bind(limit).all();
        return json({ ok: true, messages: rows.results ?? [] });
    }

    if (request.method === "POST" && p === "/agent/reply") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const b = await request.json<ReplyBody>().catch(() => ({} as ReplyBody));
        const text = (b.text ?? "").trim().slice(0, 8000);
        if (!text) return json({ ok: false, error: "text required" }, 400);
        let spokenTo: string | null = null;
        if (b.speak) {
            spokenTo = typeof b.runId === "string" && b.runId ? b.runId : await latestRunId(env);
            if (spokenTo) {
                const voiceId = typeof b.voiceId === "string" && b.voiceId ? b.voiceId : HOME_VOICE_ID;
                await env.DB.prepare("INSERT INTO live_inject (run_id, text, voice_id) VALUES (?, ?, ?)")
                    .bind(spokenTo, text.slice(0, 1200), voiceId).run();
            }
        }
        const r = await env.DB.prepare("INSERT INTO agent_thread (role, text, source, run_id) VALUES ('agent', ?, ?, ?)")
            // "spoken" even with no run: off-run the phone waits on the thread
            // for this row and plays it (founder, 2026-10-17).
            .bind(text, b.speak ? "spoken" : null, spokenTo).run();
        return json({ ok: true, id: r.meta.last_row_id, spokenTo });
    }

    if (request.method === "GET" && p === "/agent/inbox") {
        if (!isAdmin(request, env)) return json({ ok: false, error: "unauthorized" }, 401);
        const rows = await env.DB.prepare("SELECT id, text, source, run_id, meta, created_at FROM agent_thread WHERE role='user' AND seen_at IS NULL ORDER BY id ASC LIMIT 50").all();
        const items = rows.results ?? [];
        if (items.length) {
            await env.DB.prepare("UPDATE agent_thread SET seen_at = datetime('now') WHERE role='user' AND seen_at IS NULL").run();
        }
        return json({ ok: true, messages: items });
    }

    return json({ ok: false, error: "not found" }, 404);
}
