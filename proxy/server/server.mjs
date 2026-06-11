/**
 * AARC API proxy — standalone Node host.
 *
 * Adapts node:http requests to WHATWG Request, calls the SAME routing as
 * the Cloudflare Worker (proxy/src/index.ts, bundled by build.mjs into
 * dist/worker.mjs), and streams the Response back. Zero runtime deps.
 *
 * env comes from process.env plus a tiny .env loader (server/.env).
 * Cloudflare-only bindings (D1 `DB`, R2 `VOICES`) are stubbed: any route
 * that touches them gets a clear 503, while all LLM/TTS routes work fully.
 *
 * Run:  node server.mjs        (after `npm run build`)
 * Port: PORT env, default 8787.
 */
import { createServer } from "node:http";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Tiny .env loader (no deps). KEY=VALUE per line, # comments, optional quotes.
// Real environment variables always win over .env values.
// ---------------------------------------------------------------------------
function loadDotEnv(file) {
    let text;
    try { text = readFileSync(file, "utf8"); } catch { return; }
    for (const line of text.split(/\r?\n/)) {
        if (line.trimStart().startsWith("#")) continue;
        const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
        if (!m) continue;
        let v = m[2];
        if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
            v = v.slice(1, -1);
        }
        if (!(m[1] in process.env)) process.env[m[1]] = v;
    }
}
loadDotEnv(path.join(here, ".env"));

// ---------------------------------------------------------------------------
// Load the bundled Worker (same code that runs at api.aarun.club).
// ---------------------------------------------------------------------------
const distFile = path.join(here, "dist", "worker.mjs");
if (!existsSync(distFile)) {
    console.error("[aarc-proxy] dist/worker.mjs missing — run `npm run build` first.");
    process.exit(1);
}
const worker = (await import(distFile)).default;
if (typeof worker?.fetch !== "function") {
    console.error("[aarc-proxy] dist/worker.mjs has no default export with a fetch() — rebuild.");
    process.exit(1);
}

// ---------------------------------------------------------------------------
// Cloudflare binding stubs. Sibling routes (run-diagnostics) may use env.DB
// (D1) / env.VOICES (R2); those bindings don't exist on a plain VPS. Any
// property access on a stub throws, and the top-level handler maps that to
// a clean 503 — so only binding-dependent routes degrade, everything else
// (LLM/TTS) is untouched.
// ---------------------------------------------------------------------------
class BindingUnavailableError extends Error {
    constructor(binding, kind) {
        super(`Cloudflare ${kind} binding "${binding}" is not available on the standalone Node deployment`);
        this.name = "BindingUnavailableError";
        this.binding = binding;
        this.kind = kind;
    }
}

function stubBinding(name, kind) {
    return new Proxy(Object.create(null), {
        get(_target, prop) {
            if (typeof prop === "symbol") return undefined; // inspect/iterate-safe
            if (prop === "then") return undefined;          // not a thenable
            throw new BindingUnavailableError(name, kind);
        },
    });
}

// process.env passes through as plain strings (exactly what the Worker
// handlers expect for keys/models/base URLs); bindings are stubbed on top.
const env = {
    ...process.env,
    DB: stubBinding("DB", "D1"),
    VOICES: stubBinding("VOICES", "R2"),
};

// Minimal ExecutionContext — enough for ctx.waitUntil(...) fire-and-forget.
const ctx = {
    waitUntil(promise) {
        Promise.resolve(promise).catch((err) => console.error("[aarc-proxy] waitUntil:", err));
    },
    passThroughOnException() {},
};

// ---------------------------------------------------------------------------
// node:http <-> WHATWG adapters
// ---------------------------------------------------------------------------
const PORT = Number(process.env.PORT ?? 8787);

function toWebRequest(req) {
    const host = req.headers.host ?? `localhost:${PORT}`;
    const url = `http://${host}${req.url ?? "/"}`;
    const headers = new Headers();
    for (const [key, value] of Object.entries(req.headers)) {
        if (value === undefined) continue;
        if (Array.isArray(value)) {
            for (const v of value) headers.append(key, v);
        } else {
            headers.set(key, value);
        }
    }
    const method = req.method ?? "GET";
    const init = { method, headers };
    if (method !== "GET" && method !== "HEAD") {
        init.body = Readable.toWeb(req);
        init.duplex = "half"; // required when body is a stream
    }
    return new Request(url, init);
}

async function writeWebResponse(webRes, res) {
    const headers = {};
    for (const [key, value] of webRes.headers) {
        if (key === "set-cookie") continue; // handled below (multi-value)
        headers[key] = value;
    }
    const setCookies = webRes.headers.getSetCookie?.() ?? [];
    if (setCookies.length > 0) headers["set-cookie"] = setCookies;
    res.writeHead(webRes.status, headers);
    if (webRes.body) {
        await pipeline(Readable.fromWeb(webRes.body), res);
    } else {
        res.end();
    }
}

const json = (data, status) =>
    new Response(JSON.stringify(data), {
        status,
        headers: { "content-type": "application/json" },
    });

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = createServer(async (req, res) => {
    try {
        const request = toWebRequest(req);
        let response;
        try {
            response = await worker.fetch(request, env, ctx);
        } catch (err) {
            if (err instanceof BindingUnavailableError) {
                response = json(
                    {
                        ok: false,
                        error: "binding_unavailable",
                        binding: err.binding,
                        message:
                            `This route requires the Cloudflare ${err.kind} binding "${err.binding}" ` +
                            `which is not available on this standalone Node deployment. ` +
                            `Use the Worker endpoint (api.aarun.club) for this route; ` +
                            `all LLM/TTS routes work fully here.`,
                    },
                    503,
                );
            } else {
                throw err;
            }
        }
        await writeWebResponse(response, res);
    } catch (err) {
        console.error("[aarc-proxy] request failed:", err);
        if (!res.headersSent) {
            res.writeHead(500, { "content-type": "application/json" });
        }
        res.end(JSON.stringify({ ok: false, error: "internal_error" }));
    }
});

server.listen(PORT, () => {
    console.log(`[aarc-proxy] standalone Node proxy listening on :${PORT}`);
});

// Graceful shutdown for systemd restarts.
for (const signal of ["SIGTERM", "SIGINT"]) {
    process.on(signal, () => {
        console.log(`[aarc-proxy] ${signal} — shutting down`);
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 5000).unref();
    });
}
