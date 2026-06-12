/// Waitlist / "I'm interested" email collector for the public marketing site.
///
///   POST /api/waitlist        public — body {email, source?}; idempotent on email.
///   GET  /api/waitlist        admin  — X-AARC-Device (or aarc_session cookie);
///                             returns {count, recent:[…]} so the founder can see
///                             who's curious.
///
/// Every fresh signup also fires a Sentry message (level=info) so it lands in
/// the founder's inbox/alerts the moment someone leaves an address.

import { captureMessage } from "../lib/sentry";

interface Env {
    DB: D1Database;
    DEVICE_TOKEN?: string;
    SENTRY_DSN?: string;
}

const json = (data: unknown, init: ResponseInit = {}): Response =>
    new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });

// Pragmatic email shape check — not RFC-perfect, just enough to reject junk.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const SOURCE_RE = /^[a-z0-9_-]{1,32}$/i;

function readAuthorized(request: Request, env: Env): boolean {
    if (!env.DEVICE_TOKEN) return false;
    if (request.headers.get("x-aarc-device") === env.DEVICE_TOKEN) return true;
    const cookie = request.headers.get("cookie") ?? "";
    const match = cookie.match(/(?:^|;\s*)aarc_session=([^;]+)/);
    return match?.[1] === env.DEVICE_TOKEN;
}

// MARK: - POST /api/waitlist  (public)

export async function waitlistSubmitHandler(request: Request, env: Env): Promise<Response> {
    let body: { email?: unknown; source?: unknown };
    try {
        body = (await request.json()) as typeof body;
    } catch {
        return json({ ok: false, error: "bad_json" }, { status: 400 });
    }

    const email = String(body.email ?? "").trim().toLowerCase();
    if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
        return json({ ok: false, error: "invalid_email" }, { status: 400 });
    }
    const source = SOURCE_RE.test(String(body.source ?? "")) ? String(body.source) : "site";
    const referer = (request.headers.get("referer") ?? "").slice(0, 300) || null;
    const ua = (request.headers.get("user-agent") ?? "").slice(0, 300) || null;
    const country =
        (request as unknown as { cf?: { country?: string } }).cf?.country ?? null;
    const now = new Date().toISOString();

    const result = await env.DB
        .prepare(
            "INSERT OR IGNORE INTO waitlist (email, source, referer, ua, country, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(email, source, referer, ua, country, now)
        .run();

    const isNew = (result.meta.changes ?? 0) > 0;
    if (isNew && env.SENTRY_DSN) {
        // Fire-and-forget founder notification; never block the response on it.
        try {
            await captureMessage(env, `Waitlist signup: ${email}`, "info", {
                email,
                source,
                country: country ?? "",
            });
        } catch {
            /* notification is best-effort */
        }
    }

    // Always report success to the visitor — whether brand new or a repeat,
    // they're on the list. Don't leak whether the address already existed.
    return json({ ok: true, isNew });
}

// MARK: - GET /api/waitlist  (admin)

export async function waitlistListHandler(request: Request, env: Env): Promise<Response> {
    if (!readAuthorized(request, env)) {
        return json({ ok: false, error: "unauthorized" }, { status: 401 });
    }
    const countRow = await env.DB
        .prepare("SELECT COUNT(*) AS n FROM waitlist")
        .first<{ n: number }>();
    const { results } = await env.DB
        .prepare(
            "SELECT email, source, country, created_at FROM waitlist ORDER BY created_at DESC LIMIT 500",
        )
        .all();
    return json({ ok: true, count: countRow?.n ?? 0, recent: results });
}
