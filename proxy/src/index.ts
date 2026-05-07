interface Env {
  // Phase 1+: ANTHROPIC_API_KEY: string;
  // Phase 4+:  ELEVENLABS_API_KEY: string;
}

const json = (data: unknown, init: ResponseInit = {}): Response =>
  new Response(JSON.stringify(data), {
    ...init,
    headers: { "content-type": "application/json", ...(init.headers ?? {}) },
  });

export default {
  async fetch(request: Request, _env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/ping") {
      return json({ ok: true, ts: Date.now(), service: "aarc-api" });
    }

    return json({ ok: false, error: "not_found", path: url.pathname }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
