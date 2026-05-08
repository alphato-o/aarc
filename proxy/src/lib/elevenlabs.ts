/**
 * ElevenLabs Text-to-Speech adapter. Returns raw MP3 bytes that the
 * client caches and plays via AVAudioPlayer.
 *
 * Model choice:
 *   eleven_multilingual_v2  — best quality, ~3-5s latency
 *   eleven_turbo_v2_5       — faster, slightly lower quality
 *
 * Voice settings tuned for Roast Coach: low-ish stability for expressive
 * delivery, higher style for theatrical sass.
 */

const ELEVENLABS_BASE = "https://api.elevenlabs.io/v1";

export interface ElevenLabsParams {
    apiKey: string;
    text: string;
    voiceId: string;
    modelId?: string;
    stability?: number;
    similarityBoost?: number;
    style?: number;
}

export async function callElevenLabs(params: ElevenLabsParams): Promise<ArrayBuffer> {
    const url = `${ELEVENLABS_BASE}/text-to-speech/${encodeURIComponent(params.voiceId)}`;
    const body = {
        text: params.text,
        model_id: params.modelId ?? "eleven_multilingual_v2",
        voice_settings: {
            stability: params.stability ?? 0.4,
            similarity_boost: params.similarityBoost ?? 0.75,
            style: params.style ?? 0.7,
            use_speaker_boost: true,
        },
    };
    const response = await fetch(url, {
        method: "POST",
        headers: {
            "xi-api-key": params.apiKey,
            "Content-Type": "application/json",
            Accept: "audio/mpeg",
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const errText = await response.text().catch(() => "<no body>");
        throw new ElevenLabsError(
            `ElevenLabs ${response.status}: ${errText}`,
            response.status,
        );
    }

    return await response.arrayBuffer();
}

export class ElevenLabsError extends Error {
    constructor(
        message: string,
        public readonly httpStatus: number,
    ) {
        super(message);
        this.name = "ElevenLabsError";
    }
}
