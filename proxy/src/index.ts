import { generateScriptHandler } from "./routes/generateScript";
import { dynamicLineHandler } from "./routes/dynamicLine";
import { reactLineHandler } from "./routes/reactLine";
import { musicCommentHandler } from "./routes/musicComment";
import { ttsHandler } from "./routes/tts";
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
import { landingHandler } from "./routes/landing";
import { waitlistSubmitHandler, waitlistListHandler } from "./routes/waitlist";
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
    /// Shared secret for ingest writes + replay reads (wrangler secret).
    DEVICE_TOKEN?: string;
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

    if (request.method === "POST" && url.pathname === "/generate-script") {
        return generateScriptHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/dynamic-line") {
        return dynamicLineHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/react-line") {
        return reactLineHandler(request, env);
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

    if (request.method === "POST" && url.pathname === "/ingest-run") {
        return ingestRunHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/ingest-audio") {
        return ingestAudioHandler(request, env);
    }

    if (request.method === "POST" && url.pathname === "/api/waitlist") {
        return waitlistSubmitHandler(request, env);
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
