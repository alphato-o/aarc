import AVFoundation
import Speech

/// One uninterrupted stretch of a Control Room line: the mic goes to an m4a
/// file and, at the same time, into on-device speech recognition listening
/// for the stop phrase.
///
/// Why a phrase (founder, 2026-10-17): the earbuds' mic is the only one close
/// enough to his mouth in a race, and while it is open (Bluetooth HFP) the
/// Powerbeats are in call mode, so the long-press no longer reaches Siri.
/// His voice is the one control that still works. On-device so it works in
/// the no-signal start corral.
///
/// Not main-actor: the tap and the recogniser call back on their own threads.
final class TalkbackCapture: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 16_000
    private var level: Float = -160
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restarts = 0
    private var fired = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private(set) var speechState = "off"
    var onStopPhrase: (@Sendable () -> Void)?

    var seconds: Double { lock.withLock { Double(framesWritten) / sampleRate } }
    var currentLevel: Float { lock.withLock { level } }
    var isRunning: Bool { engine.isRunning }

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "talkback", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format"])
        }
        let f = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ], commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        lock.withLock { file = f; framesWritten = 0; sampleRate = fmt.sampleRate }
        startRecognition()
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in self?.consume(buf) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let req = request, t = task
        request = nil; task = nil; file = nil   // releasing the file finalises it
        lock.unlock()
        req?.endAudio()
        t?.cancel()
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        var db: Float = -160
        if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = (sum / Float(n)).squareRoot()
            if rms > 0 { db = 20 * log10(rms) }
        }
        lock.lock()
        try? file?.write(from: buf)
        framesWritten += AVAudioFramePosition(buf.frameLength)
        level = db
        let req = request
        lock.unlock()
        req?.append(buf)
    }

    // MARK: - Stop phrase

    /// "over and out" at the end of what he said. The recogniser hears it as
    /// several spellings; the ending is what counts, so a mid-sentence use
    /// that carries on does not send.
    static func endsWithStopPhrase(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard t.count >= 3 else { return false }
        let tail = Array(t.suffix(3))
        return tail[0] == "over" && ["and", "an", "n", "in"].contains(tail[1]) && tail[2] == "out"
    }

    private func startRecognition() {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized, let r = recognizer, r.isAvailable else {
            speechState = "unavailable auth=\(status.rawValue) available=\(recognizer?.isAvailable ?? false)"
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        speechState = r.supportsOnDeviceRecognition ? "on-device" : "server-only"
        lock.withLock { request = req }
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result, Self.endsWithStopPhrase(result.bestTranscription.formattedString) {
                self.fire()
            } else if result?.isFinal == true || error != nil {
                self.restartRecognition()
            }
        }
    }

    /// A recognition task ends on its own (a final result, a timeout);
    /// start another so the phrase is caught however long he talks.
    private func restartRecognition() {
        lock.lock()
        let stopped = file == nil
        let old = request
        request = nil
        restarts += 1
        let tooMany = restarts > 30
        lock.unlock()
        old?.endAudio()
        guard !stopped, !tooMany, !fired else { return }
        startRecognition()
    }

    private func fire() {
        let first = lock.withLock { () -> Bool in
            if fired { return false }
            fired = true
            return true
        }
        if first { onStopPhrase?() }
    }

    /// Ask once, in the foreground: a background start cannot show the prompt.
    static func requestSpeechAuthorizationIfNeeded() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }
}
