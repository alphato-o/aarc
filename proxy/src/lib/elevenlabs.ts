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
 * Voice settings = the ElevenLabs WEBSITE DEFAULTS, on purpose. v3 handles
 * emotion via inline tags ([screams], [moans], [laughs]); the `style`
 * exaggeration knob is NOT for that — pushing it above the default 0 makes the
 * voice over-perform and DRIFT OFF its native accent (it'd scream in a wandering
 * accent instead of English-English). So style stays 0 and we lean entirely on
 * the tags + the voice's own accent. stability 0.5 (Natural) / similarity 0.75 /
 * speaker_boost on are the playground defaults too.
 *
 * baseUrl is configurable (ELEVENLABS_BASE_URL) so TTS can route through a
 * Concessionaire transparent-carrier gateway (https://<host>/elevenlabs/v1) instead of
 * api.elevenlabs.io directly — same path shape + xi-api-key auth + audio/mpeg response,
 * the gateway swaps the key + egresses through the fleet. Default is api.elevenlabs.io.
 */

const DEFAULT_ELEVENLABS_BASE = "https://api.elevenlabs.io/v1";

export interface ElevenLabsParams {
    apiKey: string;
    text: string;
    voiceId: string;
    modelId?: string;
    stability?: number;
    similarityBoost?: number;
    style?: number;
    /** Override the API base (e.g. a Concessionaire gateway). Default api.elevenlabs.io. */
    baseUrl?: string;
}

/// 64 kbps mono: half the 128 kbps default for a thin China link (about
/// 10 KB/s on 19 Oct). 32 kbps was tried on 21 Oct and sounded bad.
export const TTS_OUTPUT_FORMAT = "mp3_44100_64";
/// Eleven v4 since 21 Oct 2026: "subtly better" by ear, and the prompts now
/// write v4 direction tags.
export const TTS_MODEL = "eleven_v4";

export async function callElevenLabs(params: ElevenLabsParams): Promise<ArrayBuffer> {
    const base = (params.baseUrl || DEFAULT_ELEVENLABS_BASE).replace(/\/+$/, "");
    const url = `${base}/text-to-speech/${encodeURIComponent(params.voiceId)}?output_format=${TTS_OUTPUT_FORMAT}`;
    const body = {
        text: params.text,
        model_id: params.modelId ?? TTS_MODEL,
        voice_settings: {
            stability: params.stability ?? 0.5,
            similarity_boost: params.similarityBoost ?? 0.75,
            style: params.style ?? 0,          // website default — 0.5 drifted the accent
            use_speaker_boost: true,
        },
    };
    // One retry on a rate limit, a 5xx or a hung call: a phone waiting on
    // this line has no other source for it.
    let response: Response | null = null;
    for (let attempt = 0; attempt < 2; attempt++) {
        try {
            response = await fetch(url, {
                method: "POST",
                headers: {
                    "xi-api-key": params.apiKey,
                    "Content-Type": "application/json",
                    Accept: "audio/mpeg",
                },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(40_000),
            });
        } catch (e) {
            if (attempt === 1) throw new ElevenLabsError(`ElevenLabs unreachable: ${e instanceof Error ? e.message : e}`, 504);
            continue;
        }
        if (response.ok || attempt === 1 || !(response.status === 429 || response.status >= 500)) break;
        await new Promise((r) => setTimeout(r, 800));
    }
    if (!response) throw new ElevenLabsError("ElevenLabs: no response", 504);

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
