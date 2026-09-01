/**
 * A minimal RFC6455 server, deliberately hand-rolled.
 *
 * The gateway advertises "zero runtime deps" and that is worth keeping: it is
 * deployed into a container from a Dockerfile with no npm install step, so a
 * dependency here is a build-pipeline change, not just a line in package.json.
 * What we need is also a narrow slice of the protocol — the phone sends binary
 * audio and one text sentinel, we send back small JSON strings — so the parts
 * that make WebSocket hairy (extensions, permessage-deflate, continuation of
 * huge frames) never arise.
 *
 * It does handle the parts that DO arise and are easy to get wrong:
 *   - client frames are always masked; unmasking is mandatory
 *   - 16- and 64-bit extended lengths
 *   - fragmentation (continuation frames)
 *   - ping/pong so an idle mid-run socket is not reaped
 *   - close handshake
 */

import { createHash } from "node:crypto";

// RFC6455 §1.3. Note the last group: C5AB0DC85B11, not 5AB0DC85B11F. Getting
// this wrong produces a handshake that looks perfectly well-formed and is
// rejected by every client with "incorrect hash", which sends you hunting in
// the framing code instead of the one constant that is wrong.
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const OP_CONT = 0x0, OP_TEXT = 0x1, OP_BIN = 0x2;
const OP_CLOSE = 0x8, OP_PING = 0x9, OP_PONG = 0xa;

export function isWebSocketUpgrade(req) {
    return (req.headers.upgrade || "").toLowerCase() === "websocket";
}

/**
 * Complete the handshake and return a tiny socket wrapper.
 * `onMessage({ type: 'binary'|'text', data })`.
 */
export function acceptWebSocket(req, socket, { onMessage, onClose, head } = {}) {
    const key = req.headers["sec-websocket-key"];
    if (!key) { socket.destroy(); return null; }
    const accept = createHash("sha1").update(key + GUID).digest("base64");
    socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    socket.setNoDelay(true);   // audio packets are small and latency-critical

    // Node hands us any bytes that arrived after the handshake request in the
    // SAME tcp segment. Dropping them loses the client's first frames, which
    // for a runner shouting a short sentence can be most of it.
    let buf = head?.length ? Buffer.from(head) : Buffer.alloc(0);
    let fragOp = null;
    let fragChunks = [];
    let closed = false;

    function send(opcode, payload) {
        if (closed || socket.destroyed) return;
        const len = payload.length;
        let header;
        if (len < 126) {
            header = Buffer.alloc(2);
            header[1] = len;
        } else if (len < 65536) {
            header = Buffer.alloc(4);
            header[1] = 126;
            header.writeUInt16BE(len, 2);
        } else {
            header = Buffer.alloc(10);
            header[1] = 127;
            header.writeBigUInt64BE(BigInt(len), 2);
        }
        header[0] = 0x80 | opcode;   // FIN + opcode; server frames are unmasked
        socket.write(Buffer.concat([header, payload]));
    }

    function deliver(op, payload) {
        if (op === OP_TEXT) onMessage?.({ type: "text", data: payload.toString("utf8") });
        else if (op === OP_BIN) onMessage?.({ type: "binary", data: payload });
    }

    socket.on("data", (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        // Parse as many complete frames as the buffer holds.
        for (;;) {
            if (buf.length < 2) return;
            const fin = (buf[0] & 0x80) !== 0;
            const opcode = buf[0] & 0x0f;
            const masked = (buf[1] & 0x80) !== 0;
            let len = buf[1] & 0x7f;
            let offset = 2;
            if (len === 126) {
                if (buf.length < offset + 2) return;
                len = buf.readUInt16BE(offset); offset += 2;
            } else if (len === 127) {
                if (buf.length < offset + 8) return;
                const big = buf.readBigUInt64BE(offset); offset += 8;
                if (big > 8n * 1024n * 1024n) { close(1009, "frame too large"); return; }
                len = Number(big);
            }
            let mask = null;
            if (masked) {
                if (buf.length < offset + 4) return;
                mask = buf.subarray(offset, offset + 4); offset += 4;
            }
            if (buf.length < offset + len) return;   // wait for the rest
            let payload = Buffer.from(buf.subarray(offset, offset + len));
            buf = buf.subarray(offset + len);
            if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];

            if (opcode === OP_CLOSE) { close(1000, ""); return; }
            if (opcode === OP_PING) { send(OP_PONG, payload); continue; }
            if (opcode === OP_PONG) continue;

            if (opcode === OP_CONT) {
                fragChunks.push(payload);
                if (fin) { deliver(fragOp, Buffer.concat(fragChunks)); fragOp = null; fragChunks = []; }
            } else if (fin) {
                deliver(opcode, payload);
            } else {
                fragOp = opcode; fragChunks = [payload];
            }
        }
    });

    // Keep the socket warm: a runner can be quiet for a long stretch mid-run
    // and we do not want an intermediary reaping the connection.
    const ping = setInterval(() => send(OP_PING, Buffer.alloc(0)), 20000);

    function close(code = 1000, reason = "") {
        if (closed) return;
        clearInterval(ping);
        try {
            const body = Buffer.alloc(2 + Buffer.byteLength(reason));
            body.writeUInt16BE(code, 0);
            body.write(reason, 2);
            // Write the close frame BEFORE flipping the flag: send() refuses to
            // write once `closed` is set, so setting it first means the peer
            // never receives a close frame and reports a 1006 abnormal closure
            // instead of the clean code we meant to send.
            send(OP_CLOSE, body);
        } catch { /* socket already gone */ }
        closed = true;
        try { socket.end() } catch { /* ditto */ }
        onClose?.();
    }

    socket.on("close", () => { if (!closed) { closed = true; clearInterval(ping); onClose?.(); } });
    socket.on("error", () => { if (!closed) { closed = true; clearInterval(ping); onClose?.(); } });

    return {
        sendText: (s) => send(OP_TEXT, Buffer.from(s, "utf8")),
        close,
        get isOpen() { return !closed && !socket.destroyed },
    };
}
