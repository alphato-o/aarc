import { generateScriptHandler } from "./routes/generateScript";

interface Env {
    OPENROUTER_API_KEY?: string;
    OPENROUTER_MODEL?: string;
    ANTHROPIC_API_KEY?: string;
    ANTHROPIC_MODEL?: string;
}

const json = (data: unknown, init: ResponseInit = {}): Response =>
    new Response(JSON.stringify(data), {
        ...init,
        headers: { "content-type": "application/json", ...(init.headers ?? {}) },
    });

export default {
    async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
        const url = new URL(request.url);

        if (request.method === "GET" && url.pathname === "/ping") {
            return json({ ok: true, ts: Date.now(), service: "aarc-api" });
        }

        if (request.method === "POST" && url.pathname === "/generate-script") {
            return generateScriptHandler(request, env);
        }

        return json(
            { ok: false, error: "not_found", path: url.pathname },
            { status: 404 },
        );
    },
} satisfies ExportedHandler<Env>;
