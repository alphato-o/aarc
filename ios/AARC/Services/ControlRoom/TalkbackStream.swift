import AVFoundation

/// Streams a Control Room line to the gateway's live ASR while he talks, so
/// the transcript is ready the moment he says "over and out" (measured 17 Oct:
/// final 0.4 s after the end of speech, against ~11 s for upload-then-batch).
///
/// Tiered: if the socket never opens, errors, or a send fails (no signal at
/// the start, a dead zone, the gateway down), `finish` returns nil and the
/// recorder falls back to uploading the file, exactly as before.
///
/// Not main-actor: the audio tap feeds it on the realtime thread.
final class TalkbackStream: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var pump: PCMPump?
    private var ready = false
    private var failure: String?
    private var partial = ""
    private var finalText = ""
    private var closed = false
    private(set) var packets = 0

    /// The running transcript so far (empty until the first words).
    var currentText: String { lock.withLock { finalText.isEmpty ? partial : finalText } }

    var state: String {
        lock.withLock { failure.map { "failed: \($0)" } ?? (ready ? "live" : "connecting") }
    }

    init(endpoint: URL, token: String) {
        var req = URLRequest(url: endpoint)
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.timeoutInterval = 8
        let ws = URLSession.shared.webSocketTask(with: req)
        let p = PCMPump(packetBytes: 6_400) { [weak self] packet in
            ws.send(.data(packet)) { error in
                guard let self else { return }
                self.lock.withLock {
                    if let error, self.failure == nil { self.failure = "send: \(error.localizedDescription)" }
                    if error == nil { self.packets += 1 }
                }
            }
        }
        p.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        task = ws
        pump = p
        ws.resume()
        receive(ws)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let p = lock.withLock { failure == nil ? pump : nil }
        p?.feed(buffer)
    }

    /// The transcript, or nil when the stream cannot be trusted and the file
    /// upload should be used instead.
    func finish(timeout: TimeInterval = 4) async -> String? {
        let (ws, p, ok) = lock.withLock { (task, pump, failure == nil && ready) }
        guard let ws, ok else { cancel(); return nil }
        if let tail = p?.drain(), !tail.isEmpty { try? await ws.send(.data(tail)) }
        try? await ws.send(.string("EOF"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let done = lock.withLock { !finalText.isEmpty || closed || failure != nil }
            if done { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let text = lock.withLock { () -> String? in
            guard failure == nil else { return nil }
            let t = (finalText.isEmpty ? partial : finalText).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        cancel()
        return text
    }

    func cancel() {
        let ws = lock.withLock { () -> URLSessionWebSocketTask? in
            let t = task; task = nil; pump = nil; return t
        }
        ws?.cancel(with: .goingAway, reason: nil)
    }

    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.withLock {
                    if !self.closed, self.task != nil, self.failure == nil { self.failure = "socket: \(error.localizedDescription)" }
                }
            case .success(let message):
                if case .string(let raw) = message,
                   let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = obj["type"] as? String {
                    let text = (obj["text"] as? String) ?? ""
                    self.lock.withLock {
                        switch type {
                        case "ready": self.ready = true
                        case "partial": self.partial = text
                        case "final": self.finalText = text; self.partial = text
                        case "error": if self.failure == nil { self.failure = "asr: \(text)" }
                        case "closed": self.closed = true
                        default: break
                        }
                    }
                }
                self.receive(ws)
            }
        }
    }
}
