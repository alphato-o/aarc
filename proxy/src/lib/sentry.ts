/**
 * Minimal Sentry envelope client over fetch — deliberately NO SDK
 * dependency (the official SDK drags in size + globals the Worker
 * doesn't need). Speaks the store/envelope protocol directly:
 * one POST to /api/<project>/envelope/ per event.
 *
 * Fully inert until the founder runs `wrangler secret put SENTRY_DSN`:
 * every entry point no-ops when env.SENTRY_DSN is undefined, and all
 * failures are swallowed — error reporting must never take down the
 * request path it is reporting on.
 */

export interface SentryEnv {
    SENTRY_DSN?: string;
}

export type SentryLevel = "fatal" | "error" | "warning" | "info" | "debug";

interface ParsedDSN {
    publicKey: string;
    host: string;
    projectId: string;
}

/** https://KEY@oNNN.ingest.sentry.io/PROJECT → key/host/project, or null. */
function parseDSN(dsn: string): ParsedDSN | null {
    try {
        const url = new URL(dsn);
        const projectId = url.pathname.replace(/\//g, "");
        if (!url.username || !url.host || !projectId) return null;
        return { publicKey: url.username, host: url.host, projectId };
    } catch {
        return null;
    }
}

const CLIENT = "aarc-proxy/1.0";

/**
 * Report a caught exception. Safe to call unconditionally — resolves
 * without doing anything when SENTRY_DSN is unset, never throws.
 */
export async function captureException(
    env: SentryEnv,
    error: unknown,
    context: Record<string, unknown> = {},
): Promise<void> {
    const name = error instanceof Error ? error.name : "Error";
    const message = error instanceof Error ? error.message : String(error);
    const stack = error instanceof Error ? error.stack : undefined;
    await send(env, {
        level: "error",
        exception: {
            values: [{ type: name, value: message }],
        },
        extra: stack ? { ...context, stack } : context,
    });
}

/**
 * Report a message-level event (e.g. upstream 5xx that we handled but
 * want visibility on). Same guarantees as captureException.
 */
export async function captureMessage(
    env: SentryEnv,
    message: string,
    level: SentryLevel = "error",
    context: Record<string, unknown> = {},
): Promise<void> {
    await send(env, {
        level,
        message: { formatted: message },
        extra: context,
    });
}

async function send(
    env: SentryEnv,
    eventBody: Record<string, unknown>,
): Promise<void> {
    if (!env.SENTRY_DSN) return;
    const dsn = parseDSN(env.SENTRY_DSN);
    if (!dsn) return;

    try {
        const eventId = crypto.randomUUID().replace(/-/g, "");
        const now = new Date().toISOString();

        const event = {
            event_id: eventId,
            timestamp: now,
            platform: "javascript",
            environment: "production",
            tags: { service: "aarc-proxy" },
            sdk: { name: "aarc.fetch-envelope", version: "1.0.0" },
            ...eventBody,
        };

        // Envelope = newline-delimited JSON: header, item header, item.
        const envelope =
            JSON.stringify({ event_id: eventId, sent_at: now, dsn: env.SENTRY_DSN }) +
            "\n" +
            JSON.stringify({ type: "event" }) +
            "\n" +
            JSON.stringify(event);

        await fetch(`https://${dsn.host}/api/${dsn.projectId}/envelope/`, {
            method: "POST",
            headers: {
                "content-type": "application/x-sentry-envelope",
                "x-sentry-auth":
                    `Sentry sentry_version=7, sentry_client=${CLIENT}, sentry_key=${dsn.publicKey}`,
            },
            body: envelope,
            // A hung ingest endpoint must not stall the worker.
            signal: AbortSignal.timeout(3000),
        });
    } catch {
        // Reporting failures are intentionally silent.
    }
}
