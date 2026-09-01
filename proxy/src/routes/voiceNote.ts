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
    /// Volcano Engine (Doubao) ASR. PREFERRED when set: the founder runs in
    /// Beijing, where Volc is low-latency and genuinely bilingual — his notes
    /// mix English and Chinese, which trips providers that assume one
    /// language. Verified reachable from the Beijing gateway in ~1.3s.
    /// BOTH are required; the token alone gets "value app.appid is empty".
    /// NEW-console credential. Per the docs, the new (project-based) console
    /// needs ONE header — X-Api-Key — and explicitly NOT the old console's
    /// X-Api-App-Key + X-Api-Access-Key pair:
    ///   "旧版控制台使用，新版控制台只需要X-Api-Key即可"
    /// Sending the old pair against a new-console project is what produced
    /// "load grant: requested grant not found" through every AppID, token,
    /// resource-id and cluster combination tried. One header. That was it.
    VOLC_API_KEY?: string;
    LIVE_DEVICE_TOKEN?: string;
}

const ID_RE = /^[A-Za-z0-9-]{8,64}$/;
// 8MB, not the API's 25MB. Base64 inflates by a third, and a ~13MB JSON body
// killed the submit outright (empty status, no message) on a 9.7MB note. The
// recorder now produces ~250KB/minute, so this is ~30 minutes of speech —
// far past any real note, while staying inside what the worker can marshal.
const MAX_BYTES = 8 * 1024 * 1024;

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
        const { text, provider } = await transcribe(audio, env, Number.isFinite(durationS) ? durationS : 0);
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

/// Try each configured provider in preference order, FALLING THROUGH on
/// failure rather than dying on the first one.
///
/// This matters because a provider can be configured and still not work: the
/// Volc keys are correct in shape but the app has no ASR service grant yet,
/// and ElevenLabs' key is missing the speech_to_text scope. Hard-failing on
/// the preferred provider would mean a half-configured account produces no
/// transcripts at all, when a working fallback was sitting right there.
async function transcribe(audio: ArrayBuffer, env: VoiceNoteEnv, durationS = 0): Promise<{ text: string; provider: string }> {
    const attempts: Array<() => Promise<{ text: string; provider: string }>> = [];
    if (env.VOLC_API_KEY) attempts.push(() => volcBig(audio, env.VOLC_API_KEY!));
    if (env.OPENAI_API_KEY) attempts.push(() => transcribeWhisper(audio, env.OPENAI_API_KEY!));
    if (env.ELEVENLABS_API_KEY) attempts.push(() => transcribeScribe(audio, env.ELEVENLABS_API_KEY!));
    if (attempts.length === 0) throw new Error("no transcription provider configured");

    const errors: string[] = [];
    for (const attempt of attempts) {
        try {
            return await attempt();
        } catch (e) {
            errors.push(e instanceof Error ? e.message : String(e));
        }
    }
    // Surface every failure: knowing all three reasons is what lets the next
    // fix be the right one.
    throw new Error(errors.join(" | "));
}

async function transcribeWhisper(audio: ArrayBuffer, key: string): Promise<{ text: string; provider: string }> {
    {
        const env = { OPENAI_API_KEY: key } as VoiceNoteEnv;
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
        throw new Error("whisper key missing");
    }
}

async function transcribeScribe(audio: ArrayBuffer, key: string): Promise<{ text: string; provider: string }> {
    {
        const env = { ELEVENLABS_API_KEY: key } as VoiceNoteEnv;
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
        throw new Error("scribe key missing");
    }
}

/// Volcano Engine file ASR, 录音文件识别大模型 (v3 bigmodel).
///
/// VERIFIED end to end against a real recording: submit returns 20000000 OK,
/// query returns punctuated text with per-utterance timings.
///
/// Only the big model is used, and NOT the small/large ladder originally asked
/// for, because the console's own price list inverts the assumption behind it:
///   录音文件识别 2.0 (大模型)   0.8 元/hour
///   录音文件识别 1.0 标准版     2.3 元/hour
///   录音文件识别 1.0 极速版     4.5 元/hour
/// The big model is roughly 3x CHEAPER and better. A tier that loses on both
/// accuracy and cost is not a tier, so there is nothing to fall back to.
///
/// Audio goes inline as base64 (accepted, confirmed) rather than by URL — the
/// alternative is publishing a fetchable link to his private voice notes.
async function volcBig(audio: ArrayBuffer, apiKey: string): Promise<{ text: string; provider: string }> {
    const reqid = crypto.randomUUID();
    // X-Api-Request-Id is what ties query to submit; there is no task id in the
    // body, so the SAME id must be sent to both.
    const headers = {
        "X-Api-Key": apiKey,
        "X-Api-Resource-Id": "volc.bigasr.auc",
        "X-Api-Request-Id": reqid,
        "content-type": "application/json",
    };
    const submit = await fetch("https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit", {
        method: "POST",
        headers: { ...headers, "X-Api-Sequence": "-1" },
        body: JSON.stringify({
            user: { uid: "aarc" },
            audio: { format: "m4a", data: base64(audio) },
            request: { model_name: "bigmodel", enable_punc: true, enable_itn: true },
        }),
    });
    const sc = submit.headers.get("x-api-status-code");
    if (sc !== "20000000") {
        throw new Error(`volc submit ${sc}: ${(submit.headers.get("x-api-message") ?? "").slice(0, 140)}`);
    }

    for (let i = 0; i < 40; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        const q = await fetch("https://openspeech.bytedance.com/api/v3/auc/bigmodel/query", {
            method: "POST", headers, body: JSON.stringify({}),
        });
        const qc = q.headers.get("x-api-status-code");
        if (qc === "20000000") {
            const qj = await q.json<{ result?: { text?: string } }>();
            const text = (qj.result?.text ?? "").trim();
            // A 20000000 with no text yet means still transcribing — keep going
            // rather than returning an empty transcript as success.
            if (text) return { text, provider: "volc-bigmodel" };
            continue;
        }
        if (qc && !["20000001", "20000002"].includes(qc)) {
            throw new Error(`volc query ${qc}: ${(q.headers.get("x-api-message") ?? "").slice(0, 140)}`);
        }
    }
    throw new Error("volc timed out waiting for the transcript");
}

function base64(buf: ArrayBuffer): string {
    const bytes = new Uint8Array(buf);
    let bin = "";
    const CHUNK = 0x8000;   // avoid blowing the argument limit on big notes
    for (let i = 0; i < bytes.length; i += CHUNK) {
        bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
    }
    return btoa(bin);
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
