import { callLLM, LLMEnv } from "../lib/llm";
import { captureMessage, SentryEnv } from "../lib/sentry";

/// Post-run voice notes: store the audio, transcribe it, tidy the text.
///
/// Founder asked for this in a voice note ABOUT voice notes: he wants to talk
/// into the phone the moment he stops, while the memory is fresh, and later
/// read it back — "in both original voice audio and cleaned up text". So we
/// keep both, and we keep them separately: the verbatim transcript is the only
/// record of what he actually said, and a tidied version that overwrote it
/// would be a lossy edit of his own words.
///
/// Transcription provider: he asked for "a whisper API". OpenAI's Whisper is
/// used when OPENAI_API_KEY is present. It is NOT provisioned on this worker
/// today, so the default path is ElevenLabs Scribe, whose key we already have
/// — the feature works now rather than waiting on a secret, and upgrades to
/// real Whisper the moment one is added. Whichever ran is recorded per note so
/// the transcript's provenance is never a guess.
export interface VoiceNoteEnv extends LLMEnv, SentryEnv {
    DB: D1Database;
    VOICES?: R2Bucket;
    ELEVENLABS_API_KEY?: string;
    OPENAI_API_KEY?: string;
    LIVE_DEVICE_TOKEN?: string;
}

const ID_RE = /^[A-Za-z0-9-]{8,64}$/;
const MAX_BYTES = 25 * 1024 * 1024;   // 25MB: both APIs cap here

function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}
function isDevice(req: Request, env: VoiceNoteEnv): boolean {
    return !!env.LIVE_DEVICE_TOKEN && req.headers.get("x-aarc-device") === env.LIVE_DEVICE_TOKEN;
}

export async function voiceNoteHandler(request: Request, url: URL, env: VoiceNoteEnv): Promise<Response> {
    if (!isDevice(request, env)) return json({ ok: false, error: "unauthorized" }, 401);

    // GET /voice-note?runId=  — the phone polls for finished transcripts.
    if (request.method === "GET") {
        const runId = url.searchParams.get("runId");
        const noteId = url.searchParams.get("noteId");
        if (noteId) {
            const row = await env.DB.prepare(
                "SELECT note_id, run_id, created_at, duration_s, status, provider, raw_text, clean_text, error FROM voice_note WHERE note_id = ?",
            ).bind(noteId).first();
            return json({ ok: true, note: row ?? null });
        }
        if (!runId) return json({ ok: false, error: "runId or noteId required" }, 400);
        const res = await env.DB.prepare(
            "SELECT note_id, run_id, created_at, duration_s, status, provider, raw_text, clean_text, error FROM voice_note WHERE run_id = ? ORDER BY created_at",
        ).bind(runId).all();
        return json({ ok: true, notes: res.results ?? [] });
    }

    if (request.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);

    const runId = url.searchParams.get("runId") ?? "";
    const noteId = url.searchParams.get("noteId") ?? "";
    const durationS = Number(url.searchParams.get("duration") ?? "0");
    if (!ID_RE.test(runId) || !ID_RE.test(noteId)) {
        return json({ ok: false, error: "invalid runId or noteId" }, 400);
    }

    const audio = await request.arrayBuffer();
    if (audio.byteLength === 0) return json({ ok: false, error: "empty body" }, 400);
    if (audio.byteLength > MAX_BYTES) return json({ ok: false, error: "audio too large" }, 413);

    // 1. Keep the audio FIRST. Transcription can fail and be retried; a
    //    recording the runner can never make again cannot.
    const audioKey = `voicenotes/${runId}/${noteId}.m4a`;
    if (env.VOICES) {
        await env.VOICES.put(audioKey, audio, { httpMetadata: { contentType: "audio/mp4" } });
    }
    await env.DB.prepare(
        "INSERT INTO voice_note (note_id, run_id, audio_key, duration_s, status) VALUES (?,?,?,?,'pending') " +
        "ON CONFLICT(note_id) DO UPDATE SET audio_key=excluded.audio_key, duration_s=excluded.duration_s",
    ).bind(noteId, runId, env.VOICES ? audioKey : null, Number.isFinite(durationS) ? durationS : 0).run();

    // 2. Transcribe + tidy. The phone does this on a detached task and polls,
    //    so a slow model here never blocks him getting on with his evening.
    try {
        const { text, provider } = await transcribe(audio, env);
        const clean = await tidy(text, env);
        await env.DB.prepare(
            "UPDATE voice_note SET status='done', provider=?, raw_text=?, clean_text=?, error=NULL WHERE note_id=?",
        ).bind(provider, text, clean, noteId).run();
        return json({ ok: true, noteId, status: "done", provider, rawText: text, cleanText: clean });
    } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        await env.DB.prepare("UPDATE voice_note SET status='failed', error=? WHERE note_id=?")
            .bind(msg.slice(0, 300), noteId).run();
        await captureMessage(env, `voice-note transcription failed: ${msg}`, "warning", { route: "/voice-note" });
        // 200, not 5xx: the AUDIO is safe, which is the part that matters.
        // The phone can ask us to retry later.
        return json({ ok: true, noteId, status: "failed", error: msg.slice(0, 300) });
    }
}

async function transcribe(audio: ArrayBuffer, env: VoiceNoteEnv): Promise<{ text: string; provider: string }> {
    if (env.OPENAI_API_KEY) {
        const fd = new FormData();
        fd.append("file", new Blob([audio], { type: "audio/mp4" }), "note.m4a");
        fd.append("model", "whisper-1");
        const r = await fetch("https://api.openai.com/v1/audio/transcriptions", {
            method: "POST",
            headers: { authorization: `Bearer ${env.OPENAI_API_KEY}` },
            body: fd,
        });
        if (!r.ok) throw new Error(`whisper ${r.status}: ${(await r.text()).slice(0, 200)}`);
        const j = await r.json<{ text?: string }>();
        if (!j.text) throw new Error("whisper returned no text");
        return { text: j.text, provider: "openai-whisper-1" };
    }
    if (env.ELEVENLABS_API_KEY) {
        const fd = new FormData();
        fd.append("file", new Blob([audio], { type: "audio/mp4" }), "note.m4a");
        fd.append("model_id", "scribe_v1");
        const r = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
            method: "POST",
            headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
            body: fd,
        });
        if (!r.ok) throw new Error(`scribe ${r.status}: ${(await r.text()).slice(0, 200)}`);
        const j = await r.json<{ text?: string }>();
        if (!j.text) throw new Error("scribe returned no text");
        return { text: j.text, provider: "elevenlabs-scribe-v1" };
    }
    throw new Error("no transcription provider configured");
}

/// Tidy WITHOUT rewriting. He is dictating bug reports and run notes at speed,
/// so the value is in punctuation and losing the ums — not in prose polish. A
/// model that "improves" this would quietly destroy the technical detail that
/// is the entire reason he recorded it.
const TIDY_SYSTEM = `You clean up a spoken voice note into readable text.

RULES:
- Preserve MEANING and DETAIL exactly. This is often a bug report or a training
  note; every number, product name and technical term must survive verbatim.
- Remove filler ("um", "uh", "you know", "like" as filler), false starts and
  stutters. Fix punctuation, capitalisation and obvious speech-to-text errors.
- Break into short paragraphs where the topic changes. Keep his voice and word
  choices; do NOT make it more formal, more polite or more concise.
- Never add information, opinions, headings or summary. Never answer or react
  to what he said. You are a transcriptionist, not a participant.
- If a passage is genuinely unintelligible, keep it and mark it [unclear].

Return ONLY the cleaned text. No preamble, no quotes, no markdown.`;

async function tidy(raw: string, env: VoiceNoteEnv): Promise<string> {
    const trimmed = raw.trim();
    if (trimmed.length < 12) return trimmed;   // too short to be worth a call
    try {
        const r = await callLLM(
            { purpose: "summary", systemPrompt: TIDY_SYSTEM, userPrompt: trimmed, maxTokens: 2000, cacheSystem: true },
            env,
        );
        const out = r.text.trim();
        return out.length > 0 ? out : trimmed;
    } catch {
        return trimmed;   // a failed tidy must never cost him the transcript
    }
}
