import { z } from "zod";
import { callElevenLabs, ElevenLabsError } from "../lib/elevenlabs";

export interface Env {
    ELEVENLABS_API_KEY?: string;
    /// Override the ElevenLabs API base (e.g. a Concessionaire gateway
    /// https://<host>/elevenlabs/v1). Default api.elevenlabs.io. The API key above
    /// becomes the minted cnc- key when this points at the gateway.
    ELEVENLABS_BASE_URL?: string;
    /// R2 — used as a SERVER-SIDE TTS cache (keyed by voice+text+params) so
    /// identical text is never re-billed to ElevenLabs, even after a client
    /// reinstall wipes the on-device cache (the dominant test-cost leak).
    VOICES?: R2Bucket;
    /// Set ONLY on the Node gateway (server.mjs) to the CF worker origin
    /// (https://api.aarun.club). When present, /tts is proxied there so a line
    /// is generated ONCE through CF's single R2 cache — both the gateway and a
    /// direct-CF hit share that cache, killing the hedge double-charge. We must
    /// NOT key gateway-detection off `env.VOICES`: on the gateway it's a truthy
    /// Proxy stub that throws on access, so `!env.VOICES` was always false and
    /// the gateway silently took the CF path, generated fresh, and never cached.
    TTS_PROXY_ORIGIN?: string;
}

/// Stable cache key for a TTS request — same voice + text + params → same key.
async function ttsCacheKey(req: {
    text: string; voiceId: string; modelId?: string;
    stability?: number; similarityBoost?: number; style?: number;
}): Promise<string> {
    const sig = [req.voiceId, req.modelId ?? "", req.stability ?? "",
                 req.similarityBoost ?? "", req.style ?? "", req.text].join("");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(sig));
    const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `tts-cache/${req.voiceId}/${hex}.mp3`;
}

/// Max characters per request. Bumped to fit Jessica's longer erotic
/// passages (~a minute of audio); the short coach lines are nowhere near
/// it. We're billed per character, so this is a ceiling, not a target.
const MAX_TEXT = 1200;

const TTSRequestSchema = z.object({
    text: z.string().min(1).max(MAX_TEXT),
    voiceId: z.string().min(8).max(64),
    modelId: z.string().optional(),
    stability: z.number().min(0).max(1).optional(),
    similarityBoost: z.number().min(0).max(1).optional(),
    style: z.number().min(0).max(1).optional(),
});

export async function ttsHandler(request: Request, env: Env): Promise<Response> {
    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return jsonError("invalid json", 400);
    }
    const parsed = TTSRequestSchema.safeParse(body);
    if (!parsed.success) {
        return jsonError("invalid request", 400, { details: parsed.error.format() });
    }
    const req = parsed.data;

    // GATEWAY path: proxy generation to the CF worker's R2-cached /tts so a
    // line is generated ONCE and cached — this is what stops the hedge
    // double-charge (device→CF and device→gateway both resolve through the same
    // R2 cache; the second is a cache hit). Falls back to direct generation
    // only if CF is unreachable from the gateway.
    if (env.TTS_PROXY_ORIGIN) {
        try {
            const cf = await fetch(`${env.TTS_PROXY_ORIGIN}/tts`, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify(req),
            });
            if (cf.ok) {
                return new Response(cf.body, {
                    status: 200,
                    headers: { "content-type": "audio/mpeg", "x-tts-via": "gateway-cf",
                               // Forward CF's cache verdict so the device can see
                               // hit/miss even on the gateway-routed path (this is
                               // how we confirm the hedge isn't double-billing).
                               "x-tts-cache": cf.headers.get("x-tts-cache") ?? "",
                               "cache-control": "public, max-age=86400" },
                });
            }
        } catch { /* CF unreachable from the gateway — fall through to direct EL */ }
        if (!env.ELEVENLABS_API_KEY) return jsonError("ELEVENLABS_API_KEY not configured", 500);
        return await generateDirect(req, env);
    }

    if (!env.ELEVENLABS_API_KEY) {
        return jsonError("ELEVENLABS_API_KEY not configured", 500);
    }

    // CF path: server-side R2 cache — identical text → serve from R2, never
    // re-bill EL (survives client reinstalls + dedupes the hedge).
    // The R2 READ is best-effort: a transient R2 hiccup must NEVER 500 the
    // request (it did once mid-run — `R2 binding "VOICES"` errors took down
    // generation entirely). On any read failure we fall straight through to
    // ElevenLabs, so the cache is a pure optimisation that can't break TTS.
    // No R2 here (e.g. local dev without the binding) → generate directly.
    const voices = env.VOICES;
    if (!voices) return await generateDirect(req, env);

    const cacheKey = await ttsCacheKey(req);
    try {
        const hit = await voices.get(cacheKey);
        if (hit) {
            return new Response(hit.body, {
                status: 200,
                headers: { "content-type": "audio/mpeg", "x-tts-cache": "hit",
                           "cache-control": "public, max-age=86400" },
            });
        }
    } catch { /* R2 read failed — generate fresh below instead of erroring */ }

    let audio: ArrayBuffer;
    try {
        audio = await callElevenLabs({
            apiKey: env.ELEVENLABS_API_KEY,
            baseUrl: env.ELEVENLABS_BASE_URL,
            text: req.text,
            voiceId: req.voiceId,
            modelId: req.modelId,
            stability: req.stability,
            similarityBoost: req.similarityBoost,
            style: req.style,
        });
    } catch (e) {
        if (e instanceof ElevenLabsError) {
            return jsonError("upstream", e.httpStatus, { detail: e.message });
        }
        return jsonError(String(e instanceof Error ? e.message : e), 502);
    }

    // Store in the R2 cache (best-effort) so a repeat — including after a
    // client reinstall — never re-bills ElevenLabs.
    if (cacheKey) {
        try { await voices.put(cacheKey, audio, { httpMetadata: { contentType: "audio/mpeg" } }); }
        catch { /* cache write is best-effort */ }
    }

    return new Response(audio, {
        status: 200,
        headers: {
            "content-type": "audio/mpeg",
            "x-tts-cache": "miss",
            "cache-control": "public, max-age=86400",
        },
    });
}

/// Direct EL generation with no cache — gateway fallback when CF is unreachable.
async function generateDirect(req: z.infer<typeof TTSRequestSchema>, env: Env): Promise<Response> {
    try {
        const audio = await callElevenLabs({
            apiKey: env.ELEVENLABS_API_KEY!,
            baseUrl: env.ELEVENLABS_BASE_URL,
            text: req.text,
            voiceId: req.voiceId,
            modelId: req.modelId,
            stability: req.stability,
            similarityBoost: req.similarityBoost,
            style: req.style,
        });
        return new Response(audio, {
            status: 200,
            headers: { "content-type": "audio/mpeg", "x-tts-via": "gateway-direct" },
        });
    } catch (e) {
        if (e instanceof ElevenLabsError) return jsonError("upstream", e.httpStatus, { detail: e.message });
        return jsonError(String(e instanceof Error ? e.message : e), 502);
    }
}

function jsonError(error: string, status: number, extra: Record<string, unknown> = {}): Response {
    return new Response(JSON.stringify({ ok: false, error, ...extra }), {
        status,
        headers: { "content-type": "application/json" },
    });
}
