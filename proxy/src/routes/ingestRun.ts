/// Run-log ingest + replay reads.
///
/// The phone uploads one JSONL document per run (`/ingest-run`) plus,
/// optionally, the per-run pinned MP3s (`/ingest-audio` → R2, behind the
/// VOICES binding which is OFF until R2 is enabled on the account). The
/// replay UIs (web + in-app Control Room history) read via /api/runs.
///
/// Auth model — single-user app:
///   * writes: header `X-AARC-Device` must equal env.DEVICE_TOKEN
///   * reads:  the same header OR cookie `aarc_session=<token>` (browser)
/// DEVICE_TOKEN is a Worker secret: `npx wrangler secret put DEVICE_TOKEN`.

export interface Env {
    DB: D1Database;
    VOICES?: R2Bucket;
    DEVICE_TOKEN?: string;
}

interface RunEvent {
    t: number;
    wall: string;
    type: string;
    detail: string;
    data: Record<string, string>;
}

interface RunEventRow {
    t: number;
    wall: string;
    type: string;
    detail: string;
    data: string;
}

const RUN_ID_RE = /^[0-9a-fA-F-]{8,64}$/;
const AUDIO_KEY_RE = /^[0-9a-f]{16,128}$/i;

const json = (data: unknown, init: ResponseInit = {}): Response =>
    new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });

// MARK: - Auth

function deviceAuthorized(request: Request, env: Env): boolean {
    if (!env.DEVICE_TOKEN) return false;
    return request.headers.get("x-aarc-device") === env.DEVICE_TOKEN;
}

function readAuthorized(request: Request, env: Env): boolean {
    if (deviceAuthorized(request, env)) return true;
    if (!env.DEVICE_TOKEN) return false;
    const cookie = request.headers.get("cookie") ?? "";
    const match = cookie.match(/(?:^|;\s*)aarc_session=([^;]+)/);
    return match?.[1] === env.DEVICE_TOKEN;
}

const unauthorized = (): Response =>
    json({ ok: false, error: "unauthorized" }, { status: 401 });

// MARK: - POST /ingest-run

/// Body: JSONL, one event per line ({t, wall, type, detail, data}).
/// Headers: X-Run-Id (UUID), X-AARC-Device, optional Content-Encoding: gzip.
/// Idempotent: re-uploading a run replaces its previous rows.
export async function ingestRunHandler(request: Request, env: Env): Promise<Response> {
    if (!deviceAuthorized(request, env)) return unauthorized();

    const runId = request.headers.get("x-run-id");
    if (!runId || !RUN_ID_RE.test(runId)) {
        return json({ ok: false, error: "missing or invalid X-Run-Id" }, { status: 400 });
    }

    let text: string;
    try {
        const encoding = (request.headers.get("content-encoding") ?? "").toLowerCase();
        if (encoding.includes("gzip") && request.body) {
            text = await new Response(
                request.body.pipeThrough(new DecompressionStream("gzip")),
            ).text();
        } else {
            text = await request.text();
        }
    } catch {
        return json({ ok: false, error: "unreadable body" }, { status: 400 });
    }

    const events: RunEvent[] = [];
    for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
            const parsed = JSON.parse(trimmed) as Partial<RunEvent>;
            events.push({
                t: typeof parsed.t === "number" ? parsed.t : -1,
                wall: typeof parsed.wall === "string" ? parsed.wall : "",
                type: typeof parsed.type === "string" ? parsed.type : "unknown",
                detail: typeof parsed.detail === "string" ? parsed.detail : "",
                data:
                    parsed.data && typeof parsed.data === "object"
                        ? (parsed.data as Record<string, string>)
                        : {},
            });
        } catch {
            // Skip malformed lines rather than rejecting the whole run —
            // a truncated tail must not block the rest of the log.
        }
    }
    if (events.length === 0) {
        return json({ ok: false, error: "no events" }, { status: 400 });
    }

    const startedAt = events[0]?.wall ?? "";
    const uploadedAt = new Date().toISOString();

    // Replace any previous copy (retries after a half-applied failure).
    await env.DB.batch([
        env.DB.prepare("DELETE FROM run_events WHERE run_id = ?").bind(runId),
        env.DB
            .prepare(
                "INSERT OR REPLACE INTO runs (run_id, started_at, uploaded_at, event_count, meta) VALUES (?, ?, ?, ?, ?)",
            )
            .bind(runId, startedAt, uploadedAt, events.length, "{}"),
    ]);

    // Multi-row inserts (6 cols × 10 rows = 60 bound params, comfortably
    // under D1's 100-param limit), batched in transactional groups.
    const ROWS_PER_STATEMENT = 10;
    const statements: D1PreparedStatement[] = [];
    for (let i = 0; i < events.length; i += ROWS_PER_STATEMENT) {
        const chunk = events.slice(i, i + ROWS_PER_STATEMENT);
        const placeholders = chunk.map(() => "(?, ?, ?, ?, ?, ?)").join(", ");
        const bindings: (string | number)[] = [];
        for (const e of chunk) {
            bindings.push(runId, e.t, e.wall, e.type, e.detail, JSON.stringify(e.data));
        }
        statements.push(
            env.DB
                .prepare(
                    `INSERT INTO run_events (run_id, t, wall, type, detail, data) VALUES ${placeholders}`,
                )
                .bind(...bindings),
        );
    }
    const STATEMENTS_PER_BATCH = 50;
    for (let i = 0; i < statements.length; i += STATEMENTS_PER_BATCH) {
        await env.DB.batch(statements.slice(i, i + STATEMENTS_PER_BATCH));
    }

    return json({ ok: true, runId, events: events.length });
}

// MARK: - POST /ingest-audio?runId=...&key=...

/// Body: raw MP3 bytes. Stored at VOICES:runId/key.mp3. Returns 503 until
/// the R2 binding is enabled (see wrangler.toml).
export async function ingestAudioHandler(request: Request, env: Env): Promise<Response> {
    if (!deviceAuthorized(request, env)) return unauthorized();
    if (!env.VOICES) {
        return json({ ok: false, error: "R2 not enabled" }, { status: 503 });
    }

    const url = new URL(request.url);
    const runId = url.searchParams.get("runId");
    const key = url.searchParams.get("key");
    if (!runId || !RUN_ID_RE.test(runId) || !key || !AUDIO_KEY_RE.test(key)) {
        return json({ ok: false, error: "invalid runId or key" }, { status: 400 });
    }

    // Buffer rather than stream: coach lines are a few hundred KB, and a
    // buffered put avoids R2's known-length requirement on streams.
    const body = await request.arrayBuffer();
    if (body.byteLength === 0) {
        return json({ ok: false, error: "empty body" }, { status: 400 });
    }
    await env.VOICES.put(`${runId}/${key}.mp3`, body, {
        httpMetadata: { contentType: "audio/mpeg" },
    });
    return json({ ok: true, runId, key, bytes: body.byteLength });
}

// MARK: - GET /api/runs

/// Newest-first run index. Bare JSON array of run rows.
export async function listRunsHandler(request: Request, env: Env): Promise<Response> {
    if (!readAuthorized(request, env)) return unauthorized();
    const { results } = await env.DB
        .prepare(
            "SELECT run_id, started_at, uploaded_at, event_count, meta FROM runs ORDER BY started_at DESC LIMIT 500",
        )
        .all();
    return json(results);
}

// MARK: - GET /api/runs/:id/events

/// Bare JSON array of events ordered by t; `data` is parsed back to an object.
export async function runEventsHandler(
    request: Request,
    env: Env,
    runId: string,
): Promise<Response> {
    if (!readAuthorized(request, env)) return unauthorized();
    if (!RUN_ID_RE.test(runId)) {
        return json({ ok: false, error: "invalid run id" }, { status: 400 });
    }
    const { results } = await env.DB
        .prepare(
            "SELECT t, wall, type, detail, data FROM run_events WHERE run_id = ? ORDER BY t ASC",
        )
        .bind(runId)
        .all<RunEventRow>();
    const events = results.map((row) => ({
        t: row.t,
        wall: row.wall,
        type: row.type,
        detail: row.detail,
        data: safeParseObject(row.data),
    }));
    return json(events);
}

// MARK: - GET /api/runs/:id/audio/:key

/// Streams a pinned MP3 from R2. 503 until R2 is enabled; 404 if missing.
export async function runAudioHandler(
    request: Request,
    env: Env,
    runId: string,
    key: string,
): Promise<Response> {
    if (!readAuthorized(request, env)) return unauthorized();
    if (!env.VOICES) {
        return json({ ok: false, error: "R2 not enabled" }, { status: 503 });
    }
    if (!RUN_ID_RE.test(runId) || !AUDIO_KEY_RE.test(key)) {
        return json({ ok: false, error: "invalid runId or key" }, { status: 400 });
    }
    const object = await env.VOICES.get(`${runId}/${key}.mp3`);
    if (!object) {
        return json({ ok: false, error: "not_found" }, { status: 404 });
    }
    return new Response(object.body, {
        status: 200,
        headers: {
            "content-type": "audio/mpeg",
            "cache-control": "private, max-age=86400",
        },
    });
}

function safeParseObject(raw: string): Record<string, string> {
    try {
        const parsed = JSON.parse(raw) as unknown;
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
            return parsed as Record<string, string>;
        }
    } catch {
        // fall through
    }
    return {};
}
