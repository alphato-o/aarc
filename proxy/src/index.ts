import { adminAmapHandler } from "./routes/adminAmap";
import { courseHandler } from "./routes/course";
import { generateScriptHandler } from "./routes/generateScript";
import { dynamicLineHandler } from "./routes/dynamicLine";
import { reactLineHandler } from "./routes/reactLine";
import { musicCommentHandler } from "./routes/musicComment";
import { roastPoolHandler } from "./routes/roastPool";
import { rankVenuesHandler } from "./routes/rankVenues";
import { voiceNoteHandler } from "./routes/voiceNote";
import { ttsHandler } from "./routes/tts";
import { liveHandler } from "./routes/live";
import { racePageHandler } from "./routes/racePage";
import { storyHere } from "./lib/course";
import { agentHandler } from "./routes/agent";
import { venueSearchHandler } from "./routes/venueSearch";
import {
    ingestRunHandler,
    ingestAudioHandler,
    listRunsHandler,
    listDeletedRunsHandler,
    deleteRunHandler,
    restoreRunHandler,
    purgeRunHandler,
    runEventsHandler,
    runAudioHandler,
} from "./routes/ingestRun";
import { dashHandler, dashAuthPollHandler, dashAuthApproveHandler } from "./routes/dashboard";
import { mapTileHandler } from "./routes/mapTile";
import { staticMapHandler } from "./routes/staticMap";
import { ambientHandler } from "./routes/ambient";
import { airCnHandler, airCnPushHandler } from "./routes/airCn";
import { homeBaseReadoutHandler } from "./routes/homeBase";
import { generateFlash, HOME_BASE_VOICE_ID } from "./lib/homeBase";
import { landingHandler } from "./routes/landing";
import { waitlistSubmitHandler, waitlistListHandler } from "./routes/waitlist";
import { personalNotesGetHandler, personalNotesPutHandler } from "./routes/personalNotes";
import { captureException } from "./lib/sentry";

interface Env {
    OPENROUTER_API_KEY?: string;
    OPENROUTER_MODEL?: string;
    OPENROUTER_BASE_URL?: string;
    ANTHROPIC_API_KEY?: string;
    ANTHROPIC_MODEL?: string;
    ELEVENLABS_API_KEY?: string;
    ELEVENLABS_BASE_URL?: string;
    /// Sentry DSN for the aarc-proxy project. Optional — error reporting
    /// is a no-op until `wrangler secret put SENTRY_DSN`.
    SENTRY_DSN?: string;
    /// D1 (aarc-runs): per-run event log for post-run replay.
    DB: D1Database;
    /// R2 for pinned run audio — optional until R2 is enabled (wrangler.toml).
    VOICES?: R2Bucket;
    /// Optional: enables real OpenAI Whisper for voice notes. Absent today,
    /// so voice-note transcription falls back to ElevenLabs Scribe.
    OPENAI_API_KEY?: string;
    /// Shared secret for ingest writes + replay reads (wrangler secret).
    DEVICE_TOKEN?: string;
    /// Live in-run channel tokens. DEVICE = the app (start/events/end/inject-GET);
    /// ADMIN = the agent ("home", /live/status + POST /live/inject). Both are
    /// Worker secrets distinct from the ingest DEVICE_TOKEN.
    LIVE_DEVICE_TOKEN?: string;
    AMAP_KEY?: string;
    LIVE_ADMIN_TOKEN?: string;
}

const json = (data: unknown, init: ResponseInit = {}): Response =>
    new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });

async function dispatch(request: Request, env: Env, url: URL): Promise<Response> {
    // --- Host-based routing for the apex marketing site + dashboard host ---
    // One Worker is bound to multiple custom domains (api / my / apex). All
    // /api/*, /dash/auth/*, /ingest-* routes below are host-agnostic and stay
    // unchanged. Only the bare "/" landing differs by host:
    //   aarun.club/        -> public marketing page (landingHandler)
    //   my.aarun.club/     -> the dashboard (same shell as GET /dash)
    // GET /dash keeps working on every host for back-compat.
    if (request.method === "GET" && url.pathname === "/") {
        const host = url.hostname;
        if (host === "my.aarun.club" || host.startsWith("my.aarun.club")) {
            return dashHandler(request, env);
        }
        if (host === "aarun.club" || host.startsWith("aarun.club")) {
            return landingHandler(request, env);
        }
    }

    if (request.method === "GET" && url.pathname === "/ping") {
        return json({ ok: true, ts: Date.now(), service: "aarc-api" });
    }

    if (request.method === "GET" && url.pathname === "/maptile") {
        return mapTileHandler(request);
    }

    if (request.method === "POST" && url.pathname === "/ambient") {
        return ambientHandler(request, env);
    }

    if (request.method === "GET" && url.pathname === "/air-cn") {
        return airCnHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/air-cn/push") {
        if (!env.LIVE_ADMIN_TOKEN || request.headers.get("x-aarc-admin") !== env.LIVE_ADMIN_TOKEN) {
            return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
        }
        return airCnPushHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/staticmap") {
        return staticMapHandler(request);
    }

    if (request.method === "POST" && url.pathname === "/generate-script") {
        return generateScriptHandler(request, env);
    }

    // Quiet mode (founder, mid-run 2026-10-13: "tone down ricky/jess, more
    // home base"). A live home_briefing row of kind 'quiet' drops one of
    // every two live coach calls; the app treats ok:false as a skipped
    // line, nothing spoken, no fallback. Scripted/per-km lines are
    // pre-rendered on the phone and untouched.
    // Race mode (founder, 2026-10-15): the app stamps runContext.raceMode on
    // every live line call. Jessica and the music lines are withheld one in
    // two; Ricky's dynamic lines one in three, and one in three of the rest
    // comes back as a Home Base flash in Kristen's voice. Per-km lines are
    // Home Base's outright (see /home-base/readout).
    if (request.method === "POST" && ["/dynamic-line", "/react-line", "/music-comment"].includes(url.pathname)) {
        let peek: any = null;
        try { peek = await request.clone().json(); } catch { peek = null; }
        const mode = peek?.runContext?.raceMode;
        // A story on the course at this point is never withheld: that line is
        // the tour guide's (founder, 2026-10-17).
        const story = mode ? storyHere(mode, Number(peek?.runContext?.distanceMeters ?? 0)) : null;
        if ((mode === "training" || mode === "actual") && !story) {
            const withheld = { ok: false, error: "race mode: line withheld" };
            const r = Math.random();
            if (url.pathname !== "/dynamic-line") {
                if (r < 0.5) return new Response(JSON.stringify(withheld), { status: 200, headers: { "content-type": "application/json" } });
            } else {
                if (r < 0.33) return new Response(JSON.stringify(withheld), { status: 200, headers: { "content-type": "application/json" } });
                if (r < 0.55 && peek?.trigger !== "opener") {
                    const flash = await generateFlash(peek.runContext, env).catch(() => null);
                    if (flash) {
                        return new Response(JSON.stringify({ ok: true, text: flash.text, model: flash.model, voiceId: HOME_BASE_VOICE_ID }),
                            { status: 200, headers: { "content-type": "application/json" } });
                    }
                }
            }
        }
        const q = await env.DB.prepare(
            "SELECT COUNT(*) AS c FROM home_briefing WHERE kind='quiet' AND (expires_at IS NULL OR expires_at > datetime('now'))"
        ).first<{ c: number }>().catch(() => null);
        if (q && q.c > 0 && Math.random() < 0.5) {
            return new Response(JSON.stringify({ ok: false, error: "quiet mode: line withheld" }),
                { status: 200, headers: { "content-type": "application/json" } });
        }
    }
    if (request.method === "POST" && url.pathname === "/dynamic-line") {
        return dynamicLineHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/home-base/readout") {
        return homeBaseReadoutHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/react-line") {
        return reactLineHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/roast-pool") {
        return roastPoolHandler(request, env);
    }

    if (url.pathname === "/voice-note") {
        return voiceNoteHandler(request, url, env);
    }

    if (url.pathname === "/rank-venues") {
        if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
        return rankVenuesHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/music-comment") {
        return musicCommentHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/tts") {
        return ttsHandler(request, env);
    }

    if (request.method === "GET" && url.pathname === "/dash") {
        return dashHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/dash/auth/poll") {
        return dashAuthPollHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/dash/auth/approve") {
        return dashAuthApproveHandler(request, env);
    }

    if (request.method === "GET" && url.pathname.startsWith("/course/")) {
        return courseHandler(request, url);
    }
    if (url.pathname.startsWith("/admin/amap/")) {
        return adminAmapHandler(request, url, env);
    }
    if (url.pathname.startsWith("/live/")) {
        return liveHandler(request, url, env);
    }
    if (request.method === "GET" && url.pathname === "/race") {
        return racePageHandler(request, env);
    }
    if (url.pathname.startsWith("/agent/")) {
        return agentHandler(request, url, env);
    }
    if (url.pathname === "/venue-search") {
        return venueSearchHandler(request, url, env);
    }

    if (request.method === "POST" && url.pathname === "/ingest-run") {
        return ingestRunHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/ingest-audio") {
        return ingestAudioHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/api/waitlist") {
        return waitlistSubmitHandler(request, env);
    }

    if (url.pathname === "/api/personal-notes") {
        if (request.method === "GET") return personalNotesGetHandler(request, env);
        if (request.method === "PUT") return personalNotesPutHandler(request, env);
    }

    if (request.method === "POST") {
        const deleteMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/delete$/);
        if (deleteMatch?.[1]) {
            return deleteRunHandler(request, env, deleteMatch[1]);
        }
        const restoreMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/restore$/);
        if (restoreMatch?.[1]) {
            return restoreRunHandler(request, env, restoreMatch[1]);
        }
        const purgeMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/purge$/);
        if (purgeMatch?.[1]) {
            return purgeRunHandler(request, env, purgeMatch[1]);
        }
    }

    if (request.method === "GET") {
        if (url.pathname === "/api/runs") {
            return listRunsHandler(request, env);
        }
        if (url.pathname === "/api/runs/deleted") {
            return listDeletedRunsHandler(request, env);
        }
        if (url.pathname === "/api/waitlist") {
            return waitlistListHandler(request, env);
        }
        const eventsMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/events$/);
        if (eventsMatch?.[1]) {
            return runEventsHandler(request, env, eventsMatch[1]);
        }
        const audioMatch = url.pathname.match(/^\/api\/runs\/([^/]+)\/audio\/([^/]+)$/);
        if (audioMatch?.[1] && audioMatch[2]) {
            return runAudioHandler(request, env, audioMatch[1], audioMatch[2]);
        }
    }

    return json(
        { ok: false, error: "not_found", path: url.pathname },
        { status: 404 },
    );
}

export default {
    async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        const url = new URL(request.url);
        try {
            return await dispatch(request, env, url);
        } catch (e) {
            // Last-resort guard: route handlers catch their own upstream
            // failures, so anything landing here is an unexpected bug.
            ctx.waitUntil(
                captureException(env, e, {
                    route: url.pathname,
                    method: request.method,
                }),
            );
            return json(
                { ok: false, error: "internal", detail: e instanceof Error ? e.message : String(e) },
                { status: 500 },
            );
        }
    },
} satisfies ExportedHandler<Env>;
