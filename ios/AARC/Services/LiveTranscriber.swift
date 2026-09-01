import AVFoundation
import Foundation
import Observation

/// Live speech-to-text: microphone → gateway websocket → VOLC → text back.
///
/// Founder, 2026-09-01: "i want to send real time voice feedback to you (home
/// base) during run, as response to your chat, or hollar, or talking back to
/// Ricky, to Jessica, or anything... i want this to be as real time as
/// possible, so you get what i said in text via gateway as quickly as possible."
///
/// So latency is the product, not a nice-to-have, and the design follows from
/// it:
///
///   * Raw PCM, not compressed audio. Encoding to AAC would mean an encoder
///     delay of one frame plus a decode on the far side, for a stream that is
///     already only 32 KB/s. Cheap bytes beat clever bytes.
///   * 200 ms packets. Smaller packets mean more TCP overhead and more radio
///     wakeups for no gain, because ASR models do not emit faster than their
///     own window. Larger ones directly add to time-to-first-word.
///   * We send from the moment the mic opens, before the upstream socket has
///     finished connecting — the gateway buffers those first packets. A runner
///     shouting three words does not wait politely for a handshake.
///
/// The key stays on the gateway (architecture rule: no API keys in the app),
/// which is why this relays rather than dialling VOLC directly.
@MainActor
@Observable
final class LiveTranscriber {
    static let shared = LiveTranscriber()

    private(set) var isStreaming = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var status = "idle"
    /// Best transcript so far, replaced as the model revises it.
    private(set) var partial = ""
    /// Set once the stream is finalised.
    private(set) var finalText = ""
    /// Milliseconds from "start" to the first text of any kind. The number.
    private(set) var firstTextMs = 0
    private(set) var packetsSent = 0
    private(set) var lastError: String?

    private var task: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var pump: PCMPump?
    private var timer: Timer?
    private var startedAt: Date?

    /// 16 kHz mono s16le: what the gateway forwards and what every ASR model
    /// wants. 200 ms at that rate is 3200 samples, 6400 bytes.
    private static let sampleRate = 16_000.0
    private static let packetBytes = 6_400

    /// Defaults to the gateway. Overridable so the bench can be pointed at a
    /// laptop running `node server.mjs` while iterating on the relay.
    static var endpoint: URL {
        if let s = UserDefaults.standard.string(forKey: "liveASR.wsBase"),
           let u = URL(string: s.hasSuffix("/live-asr") ? s : s + "/live-asr") {
            return u
        }
        return URL(string: "wss://gateway.aarun.club:8443/live-asr")!
    }

    private static var deviceToken: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AARCLiveDeviceToken") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isStreaming else { return }
        partial = ""; finalText = ""; lastError = nil
        firstTextMs = 0; packetsSent = 0
        status = "asking for mic…"

        guard await VoiceNoteRecorder.shared.requestPermission() else {
            status = "no mic permission"
            lastError = "Microphone access is off. Settings → AARC → Microphone."
            return
        }
        guard let token = Self.deviceToken else {
            status = "no device token"
            lastError = "AARCLiveDeviceToken missing from Info.plist — this build cannot reach the gateway."
            return
        }

        startedAt = Date()
        status = "connecting…"

        var req = URLRequest(url: Self.endpoint)
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.timeoutInterval = 15
        let ws = URLSession.shared.webSocketTask(with: req)
        task = ws
        ws.resume()
        receiveLoop(ws)

        do {
            try startCapture(ws)
        } catch {
            status = "mic failed"
            lastError = error.localizedDescription
            await stop()
            return
        }

        isStreaming = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
    }

    func stop() async {
        timer?.invalidate(); timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // Flush whatever partial packet is left, then ask for the final result.
        if let tail = pump?.drain(), !tail.isEmpty, let task {
            try? await task.send(.data(tail))
        }
        pump = nil
        if let task {
            status = "finishing…"
            try? await task.send(.string("EOF"))
            // Give VOLC a moment to emit the final segment before tearing the
            // socket down; the gateway closes it for us when it does.
            try? await Task.sleep(for: .milliseconds(1200))
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        isStreaming = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if status != "error" { status = "stopped" }
    }

    // MARK: - Capture

    private func startCapture(_ ws: URLSessionWebSocketTask) throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord so a coach line still finishing does not get torn down
        // the moment he starts talking back to it.
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw StreamError.noInput }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: target)
        else { throw StreamError.noConverter }

        // The tap fires on a realtime audio thread. It must not touch main-actor
        // state, so everything it needs lives in the pump, and the only thing
        // that crosses back is a finished packet.
        let pump = PCMPump(converter: converter, target: target, packetBytes: Self.packetBytes) { packet in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming || self.task != nil else { return }
                do {
                    try await ws.send(.data(packet))
                    self.packetsSent += 1
                } catch {
                    self.note(error: "send failed: \(error.localizedDescription)")
                }
            }
        }
        self.pump = pump

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            pump.feed(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    // MARK: - Socket

    private func receiveLoop(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    // A cancel we initiated is not an error worth showing.
                    if self.isStreaming { self.note(error: error.localizedDescription) }
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receiveLoop(ws)
                }
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let text = (obj["text"] as? String) ?? ""

        switch type {
        case "ready":
            status = "listening"
        case "partial", "final":
            if firstTextMs == 0, let s = startedAt, !text.isEmpty {
                firstTextMs = Int(Date().timeIntervalSince(s) * 1000)
            }
            partial = text
            if type == "final" { finalText = text; status = "final" }
        case "error":
            note(error: text)
        case "closed":
            if finalText.isEmpty { finalText = partial }
            status = "closed"
        default:
            break
        }
    }

    private func note(error: String) {
        lastError = error
        status = "error"
    }

    enum StreamError: LocalizedError {
        case noInput, noConverter
        var errorDescription: String? {
            switch self {
            case .noInput: return "No audio input available."
            case .noConverter: return "Could not build a 16 kHz converter for this device's mic."
            }
        }
    }
}

/// Resamples whatever the mic hands us into 16 kHz mono s16le and emits
/// fixed-size packets.
///
/// Separate from `LiveTranscriber` because it runs on the realtime audio
/// thread, where main-actor isolation cannot follow. It owns everything it
/// touches and hands out only immutable `Data`.
private final class PCMPump: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let packetBytes: Int
    private let emit: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var pending = Data()

    init(converter: AVAudioConverter, target: AVAudioFormat, packetBytes: Int,
         emit: @escaping @Sendable (Data) -> Void) {
        self.converter = converter
        self.target = target
        self.packetBytes = packetBytes
        self.emit = emit
        pending.reserveCapacity(packetBytes * 2)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resample(buffer) else { return }
        var ready: [Data] = []
        lock.lock()
        pending.append(converted)
        while pending.count >= packetBytes {
            ready.append(pending.prefix(packetBytes))
            pending.removeFirst(packetBytes)
        }
        lock.unlock()
        for packet in ready { emit(packet) }
    }

    /// Whatever is left when he stops mid-packet. Usually under 200 ms, but it
    /// is often the tail of the last word.
    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}
