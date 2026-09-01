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
///   * Packets are handed to the socket from the audio thread, not bounced
///     through the main actor. One hop per packet is latency for nothing, and
///     independent Tasks do not preserve order, which would shuffle the PCM
///     stream into noise.
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
    private(set) var lastError: String?

    // Pipeline instrumentation. The first live failure was "VOLC saw no audio
    // for 8 seconds" and this class could not say whether the mic was silent,
    // the resampler was dropping everything, or the socket was refusing sends.
    // A bench that only reports the happy path is not a bench.
    private(set) var micCallbacks = 0
    private(set) var framesCaptured = 0
    private(set) var packetsSent = 0
    private(set) var bytesSent = 0
    private(set) var inputFormatDescription = "-"
    private(set) var engineRunning = false

    private var task: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var pump: PCMPump?
    private var timer: Timer?
    private var toneTimer: Timer?
    private var startedAt: Date?
    private var micWarned = false

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

    /// `testTone: true` streams a synthetic 16 kHz tone and never opens the
    /// mic. It exists to split one question into two: if the tone reaches the
    /// gateway and the mic does not, the fault is capture, not transport. That
    /// distinction took a round trip through a real run to establish once.
    func start(testTone: Bool = false) async {
        guard !isStreaming else { return }
        partial = ""; finalText = ""; lastError = nil
        firstTextMs = 0; packetsSent = 0; bytesSent = 0
        micCallbacks = 0; framesCaptured = 0; micWarned = false
        inputFormatDescription = "-"; engineRunning = false
        status = testTone ? "tone: starting…" : "asking for mic…"

        if !testTone {
            guard await VoiceNoteRecorder.shared.requestPermission() else {
                status = "no mic permission"
                lastError = "Microphone access is off. Settings → AARC → Microphone."
                return
            }
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

        // Set BEFORE capture starts: the send path checks it, and the first
        // packets can land within ~200 ms of the tap going in.
        isStreaming = true
        elapsed = 0

        if testTone {
            startTestTone(ws)
        } else {
            do {
                try startCapture(ws)
            } catch {
                status = "mic failed"
                lastError = error.localizedDescription
                await stop()
                return
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let s = startedAt else { return }
        elapsed = Date().timeIntervalSince(s)
        if let pump {
            let stats = pump.stats()
            micCallbacks = stats.callbacks
            framesCaptured = stats.frames
            packetsSent = stats.packets
            bytesSent = stats.bytes
            if let e = stats.lastError, lastError == nil { note(error: e) }
        }
        engineRunning = engine?.isRunning ?? false

        // Do not make him wait out VOLC's 8 second timeout to learn the mic is
        // dead. If nothing has arrived from the tap after 2 seconds, say so.
        if !micWarned, elapsed > 2, micCallbacks == 0, engine != nil {
            micWarned = true
            note(error: "Mic delivered no audio in 2s (engine running: \(engineRunning), format: \(inputFormatDescription)). Try the transport test to check the socket.")
        }
    }

    func stop() async {
        timer?.invalidate(); timer = nil
        toneTimer?.invalidate(); toneTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        engineRunning = false
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

    private func makePump(_ ws: URLSessionWebSocketTask) -> PCMPump {
        // Send straight from the audio thread. URLSessionWebSocketTask queues
        // internally and preserves call order; hopping each packet through a
        // detached Task would not, and out-of-order PCM is just noise.
        PCMPump(packetBytes: Self.packetBytes) { packet in
            ws.send(.data(packet)) { _ in }
        }
    }

    private func startCapture(_ ws: URLSessionWebSocketTask) throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord so a coach line still finishing does not get torn down
        // the moment he starts talking back to it.
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Read the format only AFTER the session is active, or it reports the
        // wrong rate (sometimes 0) and every later conversion is built wrong.
        let inFormat = input.outputFormat(forBus: 0)
        inputFormatDescription = "\(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch"
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw StreamError.noInput }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.sampleRate,
                                         channels: 1,
                                         interleaved: true)
        else { throw StreamError.noConverter }

        let pump = makePump(ws)
        pump.targetFormat = target
        self.pump = pump

        // Pass nil so the tap uses the node's own format. Handing installTap a
        // format that disagrees with the hardware is not an error you catch,
        // it is an assertion failure that kills the app, and the converter is
        // built from the first real buffer anyway so nothing needs to guess.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            pump.feed(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.engineRunning = engine.isRunning
    }

    /// Transport test: synthetic 200 ms packets, no microphone involved.
    private func startTestTone(_ ws: URLSessionWebSocketTask) {
        let pump = makePump(ws)
        self.pump = pump
        status = "tone: streaming"
        var phase = 0.0
        let step = 2.0 * Double.pi * 440.0 / Self.sampleRate
        toneTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            var samples = [Int16](repeating: 0, count: Self.packetBytes / 2)
            for i in samples.indices {
                samples[i] = Int16(sin(phase) * 8000)
                phase += step
            }
            pump.feedRaw(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        }
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
            if status.hasPrefix("tone") { status = "tone: relay ready" } else { status = "listening" }
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
            case .noInput: return "No audio input available (input format reported no channels)."
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
/// touches, hands out only immutable `Data`, and counts what passed through so
/// the bench can say which stage went quiet.
private final class PCMPump: @unchecked Sendable {
    /// Built lazily from the first buffer's ACTUAL format, so a device whose
    /// mic disagrees with what we predicted still works instead of silently
    /// converting nothing.
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var _targetFormat: AVAudioFormat?
    var targetFormat: AVAudioFormat? {
        get { lock.lock(); defer { lock.unlock() }; return _targetFormat }
        set { lock.lock(); _targetFormat = newValue; lock.unlock() }
    }
    private let packetBytes: Int
    private let emit: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var pending = Data()

    private var callbacks = 0
    private var frames = 0
    private var packets = 0
    private var bytes = 0
    private var failure: String?

    init(packetBytes: Int, emit: @escaping @Sendable (Data) -> Void) {
        self.packetBytes = packetBytes
        self.emit = emit
        pending.reserveCapacity(packetBytes * 2)
    }

    struct Stats { let callbacks: Int; let frames: Int; let packets: Int; let bytes: Int; let lastError: String? }

    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(callbacks: callbacks, frames: frames, packets: packets, bytes: bytes, lastError: failure)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); callbacks += 1; frames += Int(buffer.frameLength); lock.unlock()
        guard let converted = resample(buffer) else { return }
        feedRaw(converted)
    }

    /// Already 16 kHz mono s16le (the transport test path).
    func feedRaw(_ converted: Data) {
        var ready: [Data] = []
        lock.lock()
        pending.append(converted)
        while pending.count >= packetBytes {
            // Re-wrap in a fresh Data: a Data slice keeps the parent's index
            // base, which is a reliable source of off-by-everything bugs once
            // it is handed to anything that assumes zero-based storage.
            ready.append(Data(pending.prefix(packetBytes)))
            pending.removeFirst(packetBytes)
        }
        packets += ready.count
        bytes += ready.reduce(0) { $0 + $1.count }
        lock.unlock()
        for packet in ready { emit(packet) }
    }

    /// Whatever is left when he stops mid-packet. Usually under 200 ms, but it
    /// is often the tail of the last word.
    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        let out = Data(pending)
        pending.removeAll(keepingCapacity: true)
        return out
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock()
        let tgt = _targetFormat
        // Rebuild if this is the first buffer, or if the route changed under
        // us (headphones in, bluetooth connects) and the format moved with it.
        if let tgt, converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: tgt)
            converterInput = buffer.format
            if converter == nil { failure = "no converter for \(Int(buffer.format.sampleRate))Hz mic" }
        }
        let conv = converter
        lock.unlock()
        guard let conv, let tgt else { return nil }
        let ratio = tgt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: tgt, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            lock.lock(); failure = "resample: \(error.localizedDescription)"; lock.unlock()
            return nil
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}
