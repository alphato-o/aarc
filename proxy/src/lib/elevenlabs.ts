/**
 * ElevenLabs Text-to-Speech adapter. Returns raw MP3 bytes that the
 * client caches and plays via AVAudioPlayer.
 *
 * Model choice:
 *   eleven_v3                — flagship, supports inline audio tags
 *                              ([shouting], [whispering], [laughs],
 *                              [sighs], [mockingly], [enthusiastic])
 *                              for dynamic theatrical control. The
 *                              script-gen prompt sprinkles these on
 *                              moments that warrant them.
 *   eleven_multilingual_v2   — previous default, no tags, more stable.
 *   eleven_turbo_v2_5        — fastest, lowest quality.
 *
 * Voice settings tuned for Roast Coach: v3 handles emotion primarily
 * via inline tags, so the per-line `style` matters less; we keep a
 * moderate value and lean on the model emitting tags where it counts.
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
        model_id: params.modelId ?? "eleven_v3",
        voice_settings: {
            stability: params.stability ?? 0.5,
            similarity_boost: params.similarityBoost ?? 0.75,
            style: params.style ?? 0.5,
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
