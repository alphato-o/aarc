import { z } from "zod";
import { callElevenLabs, ElevenLabsError } from "../lib/elevenlabs";

export interface Env {
    ELEVENLABS_API_KEY?: string;
    /// Override the ElevenLabs API base (e.g. a Concessionaire gateway
    /// https://<host>/elevenlabs/v1). Default api.elevenlabs.io. The API key above
    /// becomes the minted cnc- key when this points at the gateway.
    ELEVENLABS_BASE_URL?: string;
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
    if (!env.ELEVENLABS_API_KEY) {
        return jsonError("ELEVENLABS_API_KEY not configured", 500);
    }

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

    return new Response(audio, {
        status: 200,
        headers: {
            "content-type": "audio/mpeg",
            // Cloudflare edge can hold the response briefly; the client
            // does its own per-text-hash disk cache anyway.
            "cache-control": "public, max-age=86400",
        },
    });
}

function jsonError(error: string, status: number, extra: Record<string, unknown> = {}): Response {
    return new Response(JSON.stringify({ ok: false, error, ...extra }), {
        status,
        headers: { "content-type": "application/json" },
    });
}
