/// Web dashboard served by the Worker, plus QR sign-in v1.
///
/// Routes (registered in src/index.ts):
///   GET  /dash               login page (no/invalid session) or app shell
///   POST /dash/auth/poll     {code} -> {status: pending|approved|unknown|expired}
///                            sets the session cookie on the approved poll
///   POST /dash/auth/approve  {code}, header X-AARC-Device == env.DEVICE_TOKEN
///                            (called by the iOS app from the aarc:// deep link)
///
/// Auth model v1: no passwords. The login page mints a random code (stored in
/// D1 table dash_auth, see migrations/0002_dash_auth.sql), shows it as a QR
/// encoding aarc://dash-auth?code=..., and polls every 2s. The phone — which
/// already holds DEVICE_TOKEN — approves the code. The approved poll receives
/// Set-Cookie aarc_session=DEVICE_TOKEN (HttpOnly, Secure, SameSite=Lax, 90d).
import { LOGIN_HTML } from "./dashboardLogin";
import { APP_HTML } from "./dashboardApp";

export interface Env {
    /// D1 database; binding shared with the runs/events data API.
    DB?: D1Database;
    /// Shared device secret (wrangler secret). Doubles as the session
    /// cookie value in auth v1 — rotating the secret invalidates sessions.
    DEVICE_TOKEN?: string;
}

const SESSION_COOKIE = "aarc_session";
const SESSION_MAX_AGE_S = 90 * 24 * 60 * 60; // 90 days
const CODE_TTL_MS = 10 * 60 * 1000; // pending codes live 10 minutes

// ---------------------------------------------------------------------------
// GET /dash
// ---------------------------------------------------------------------------
export async function dashHandler(request: Request, env: Env): Promise<Response> {
    if (!env.DEVICE_TOKEN) {
        return text("dashboard not configured: DEVICE_TOKEN secret missing", 500);
    }

    const session = getCookie(request, SESSION_COOKIE);
    if (session !== null && session === env.DEVICE_TOKEN) {
        return html(APP_HTML);
    }

    if (!env.DB) {
        return text("dashboard not configured: D1 binding DB missing", 500);
    }

    // Mint a pending code for this login page render, GC stale ones.
    const code = newCode();
    const cutoff = new Date(Date.now() - CODE_TTL_MS).toISOString();
    await env.DB.prepare("DELETE FROM dash_auth WHERE created_at < ?1").bind(cutoff).run();
    await env.DB
        .prepare("INSERT INTO dash_auth (code, created_at, approved) VALUES (?1, ?2, 0)")
        .bind(code, new Date().toISOString())
        .run();

    return html(LOGIN_HTML.replaceAll("__AUTH_CODE__", code));
}

// ---------------------------------------------------------------------------
// POST /dash/auth/poll  {code}
// ---------------------------------------------------------------------------
export async function dashAuthPollHandler(request: Request, env: Env): Promise<Response> {
    if (!env.DEVICE_TOKEN || !env.DB) return json({ ok: false, error: "not_configured" }, 500);

    const code = await readCode(request);
    if (!code) return json({ ok: false, error: "invalid request" }, 400);

    const row = await env.DB
        .prepare("SELECT created_at, approved FROM dash_auth WHERE code = ?1")
        .bind(code)
        .first<{ created_at: string; approved: number }>();

    if (!row) return json({ ok: true, status: "unknown" });

    const createdAt = Date.parse(row.created_at);
    if (!Number.isFinite(createdAt) || Date.now() - createdAt > CODE_TTL_MS) {
        await env.DB.prepare("DELETE FROM dash_auth WHERE code = ?1").bind(code).run();
        return json({ ok: true, status: "expired" });
    }

    if (row.approved !== 1) return json({ ok: true, status: "pending" });

    // Approved: consume the code (one-time use) and establish the session.
    await env.DB.prepare("DELETE FROM dash_auth WHERE code = ?1").bind(code).run();
    const cookie = [
        `${SESSION_COOKIE}=${env.DEVICE_TOKEN}`,
        "HttpOnly",
        "Secure",
        "SameSite=Lax",
        "Path=/",
        `Max-Age=${SESSION_MAX_AGE_S}`,
    ].join("; ");
    return json({ ok: true, status: "approved" }, 200, { "set-cookie": cookie });
}

// ---------------------------------------------------------------------------
// POST /dash/auth/approve  {code}  (iOS app, X-AARC-Device header)
// ---------------------------------------------------------------------------
export async function dashAuthApproveHandler(request: Request, env: Env): Promise<Response> {
    if (!env.DEVICE_TOKEN || !env.DB) return json({ ok: false, error: "not_configured" }, 500);

    const device = request.headers.get("x-aarc-device");
    if (device !== env.DEVICE_TOKEN) return json({ ok: false, error: "unauthorized" }, 401);

    const code = await readCode(request);
    if (!code) return json({ ok: false, error: "invalid request" }, 400);

    const cutoff = new Date(Date.now() - CODE_TTL_MS).toISOString();
    const result = await env.DB
        .prepare("UPDATE dash_auth SET approved = 1 WHERE code = ?1 AND created_at >= ?2")
        .bind(code, cutoff)
        .run();

    const changed = result.meta.changes ?? 0;
    if (changed < 1) return json({ ok: false, error: "unknown_or_expired_code" }, 404);
    return json({ ok: true, approved: true });
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// 20 chars from a 32-symbol alphabet (no 0/O/1/I) — ~100 bits of entropy,
/// uniform because 256 % 32 == 0.
function newCode(): string {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const buf = new Uint8Array(20);
    crypto.getRandomValues(buf);
    let out = "";
    for (const b of buf) out += alphabet.charAt(b % 32);
    return out;
}

async function readCode(request: Request): Promise<string | null> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return null;
    }
    if (typeof body !== "object" || body === null) return null;
    const code = (body as Record<string, unknown>)["code"];
    if (typeof code !== "string") return null;
    const trimmed = code.trim().toUpperCase();
    if (trimmed.length < 8 || trimmed.length > 64 || !/^[A-Z0-9]+$/.test(trimmed)) return null;
    return trimmed;
}

function getCookie(request: Request, name: string): string | null {
    const header = request.headers.get("cookie");
    if (!header) return null;
    for (const part of header.split(";")) {
        const eq = part.indexOf("=");
        if (eq < 0) continue;
        if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
    }
    return null;
}

function html(body: string, status = 200): Response {
    return new Response(body, {
        status,
        headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
        },
    });
}

function text(body: string, status = 200): Response {
    return new Response(body, {
        status,
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
}

function json(data: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
    return new Response(JSON.stringify(data), {
        status,
        headers: {
            "content-type": "application/json",
            "cache-control": "no-store",
            ...extraHeaders,
        },
    });
}
