/**
 * Live speech-to-text relay: phone  <--ws-->  gateway (Beijing)  <--ws-->  VOLC
 *
 * Why the gateway and not straight from the phone: the API key would have to
 * ship in the app, which is one of the app's locked architecture rules (no keys
 * on device). Routing through the gateway keeps the key server-side and costs
 * almost nothing in latency, because the gateway box and VOLC are both in
 * Beijing with the runner.
 *
 * Protocol, phone side (deliberately dumb so the client stays small):
 *   -> binary frames: raw 16 kHz mono 16-bit PCM, ~200 ms per packet
 *   -> text  "EOF": the runner stopped talking; flush and finish
 *   <- text  JSON  {type:"partial"|"final"|"ready"|"error", text, ms}
 *
 * VOLC's own protocol is a binary framing over websocket, implemented below:
 * a 4-byte header (version/size/type/flags/serialisation/compression) followed
 * by a big-endian payload length and the payload. Audio-only packets carry raw
 * PCM; the first packet carries a JSON config.
 *
 * Written against docs 6561/1354869 (大模型流式语音识别API). Auth follows the
 * same rule the file API taught us the hard way: the NEW console needs
 * X-Api-Key alone, NOT the old X-Api-App-Key + X-Api-Access-Key pair.
 */

import { randomUUID } from "node:crypto";

const VOLC_WS = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async";
// 豆包流式语音识别模型2.0, hour-billed. The _async endpoint only emits when the
// text actually CHANGES, which is what we want: fewer wakeups, lower latency to
// a stable result than the every-packet-echoes modes.
const RESOURCE_ID = "volc.seedasr.sauc.duration";

// ---------------------------------------------------------------------------
// VOLC binary framing
// ---------------------------------------------------------------------------
const PROTOCOL_VERSION = 0b0001;
const HEADER_SIZE = 0b0001;          // in 4-byte words

const MSG_FULL_CLIENT = 0b0001;      // JSON config
const MSG_AUDIO_ONLY = 0b0010;       // raw PCM
const MSG_FULL_SERVER = 0b1001;      // JSON result
const MSG_ERROR = 0b1111;

const FLAG_NONE = 0b0000;
const FLAG_SEQUENCE = 0b0001;        // a 4-byte sequence number follows the header
const FLAG_LAST = 0b0010;            // negative/last packet

const SER_JSON = 0b0001;
const SER_RAW = 0b0000;
const COMPRESS_NONE = 0b0000;

function buildFrame(msgType, flags, serialization, payload) {
    const header = Buffer.alloc(4);
    header[0] = (PROTOCOL_VERSION << 4) | HEADER_SIZE;
    header[1] = (msgType << 4) | flags;
    header[2] = (serialization << 4) | COMPRESS_NONE;
    header[3] = 0x00;
    const len = Buffer.alloc(4);
    len.writeUInt32BE(payload.length, 0);
    return Buffer.concat([header, len, payload]);
}

function parseFrame(buf) {
    if (buf.length < 8) return null;
    const headerWords = buf[0] & 0x0f;
    const msgType = buf[1] >> 4;
    const flags = buf[1] & 0x0f;
    const serialization = buf[2] >> 4;
    let offset = headerWords * 4;

    // Between the header and the payload length sits an OPTIONAL 4-byte field:
    // an error code on error frames, otherwise a sequence number whenever the
    // flags say one is present. Server result frames set FLAG_SEQUENCE on every
    // packet after the first, so skipping this only for errors silently reads
    // the length from four bytes too early — which yields a nonsense size and a
    // transcript that never arrives, with no error anywhere to explain it.
    let code = 0;
    if (msgType === MSG_ERROR) {
        code = buf.readUInt32BE(offset);
        offset += 4;
    } else if (flags & (FLAG_SEQUENCE | FLAG_LAST)) {
        offset += 4;
    }

    const size = buf.readUInt32BE(offset);
    offset += 4;
    const payload = buf.subarray(offset, offset + size);
    let json = null;
    if (serialization === SER_JSON && payload.length) {
        try { json = JSON.parse(payload.toString("utf8")); } catch { /* keep null */ }
    }
    return { msgType, flags, code, json };
}

/**
 * Open a VOLC streaming session.
 * `onText` gets ({ text, isFinal }) each time the transcript changes.
 */
export async function openVolcSession({ apiKey, onText, onError, onClose }) {
    const reqId = randomUUID();
    const ws = new WebSocket(VOLC_WS, {
        headers: {
            "X-Api-Key": apiKey,
            "X-Api-Resource-Id": RESOURCE_ID,
            "X-Api-Request-Id": reqId,
            "X-Api-Connect-Id": randomUUID(),
        },
    });
    ws.binaryType = "arraybuffer";

    await new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error("volc ws connect timeout")), 8000);
        ws.addEventListener("open", () => { clearTimeout(t); resolve(); }, { once: true });
        ws.addEventListener("error", (e) => { clearTimeout(t); reject(new Error(`volc ws error: ${e?.message ?? "unknown"}`)); }, { once: true });
    });

    // Config packet. 16 kHz mono s16le is what the phone sends and what every
    // ASR model wants; punctuation and ITN on so numbers read as numbers.
    const config = {
        user: { uid: "aarc" },
        audio: { format: "pcm", codec: "raw", rate: 16000, bits: 16, channel: 1 },
        request: {
            model_name: "bigmodel",
            enable_punc: true,
            enable_itn: true,
        },
    };
    ws.send(buildFrame(MSG_FULL_CLIENT, FLAG_NONE, SER_JSON, Buffer.from(JSON.stringify(config), "utf8")));

    ws.addEventListener("message", (ev) => {
        const buf = Buffer.from(ev.data);
        const f = parseFrame(buf);
        if (!f) return;
        if (f.msgType === MSG_ERROR) {
            onError?.(new Error(`volc ${f.code}: ${JSON.stringify(f.json ?? {}).slice(0, 200)}`));
            return;
        }
        if (f.msgType === MSG_FULL_SERVER && f.json) {
            const text = f.json?.result?.text ?? "";
            if (text) onText?.({ text, isFinal: (f.flags & FLAG_LAST) !== 0 });
        }
    });
    ws.addEventListener("close", () => onClose?.());
    ws.addEventListener("error", (e) => onError?.(new Error(e?.message ?? "volc ws error")));

    return {
        /** Forward one ~200ms PCM packet. */
        sendAudio(chunk) {
            if (ws.readyState !== 1) return;
            ws.send(buildFrame(MSG_AUDIO_ONLY, FLAG_NONE, SER_RAW, Buffer.from(chunk)));
        },
        /** Negative packet: no more audio, flush and finalise. */
        finish() {
            if (ws.readyState !== 1) return;
            ws.send(buildFrame(MSG_AUDIO_ONLY, FLAG_LAST, SER_RAW, Buffer.alloc(0)));
        },
        close() { try { ws.close() } catch { /* already gone */ } },
    };
}
