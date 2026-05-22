import Foundation
import AVFoundation
import Accelerate
import Observation
import OSLog

/// Real-time microphone-driven FFT equalizer.
///
/// AVAudioEngine installs a tap on the input node, the tap callback
/// runs vDSP's real-to-complex FFT on each ~1024-sample buffer, and
/// bins the magnitudes into 16 log-spaced frequency bands. The bars
/// in `KineticVisualizer` are painted directly from `bins`, so when
/// music plays loud in the room (phone speaker, Bluetooth speaker,
/// treadmill TV) the equalizer dances with the actual sound waveform.
///
/// What this *can't* do, because iOS doesn't let it: tap the audio
/// buffer that Spotify (or Apple Music, etc.) is sending to a pair of
/// Bluetooth earbuds. That buffer never reaches the microphone. There
/// is no public API around that — DRM/privacy boundary. So if music
/// is hermetic inside the runner's earbuds, the equalizer will show
/// only ambient room noise. The only fix is for music to be audible
/// to the room, which on a treadmill usually means the phone speaker
/// or a Bluetooth speaker.
///
/// Concurrency:
///   • `start()` / `stop()` are @MainActor.
///   • The AVAudioEngine tap fires on a private audio thread; we run
///     FFT there (no contention) and hop to MainActor only to publish
///     the resulting bins to Observable state.
@MainActor
@Observable
final class MicAudioCapture {
    static let shared = MicAudioCapture()

    /// 16 log-spaced frequency-band magnitudes, 0...1 normalized
    /// (with exponential-MA smoothing so the bars don't strobe).
    private(set) var bins: [Float] = Array(repeating: 0, count: 16)
    private(set) var isCapturing: Bool = false
    private(set) var permissionDenied: Bool = false
    private(set) var lastError: String?

    private let fftSize = 1024
    private let bandCount = 16
    /// Higher = smoother (more momentum), lower = more reactive (more
    /// strobing). 0.55 picks a balance that reads as "alive".
    private let smoothing: Float = 0.55

    private let engine = AVAudioEngine()
    private let processor: FFTProcessor
    private let log = Logger(subsystem: "club.aarun.AARC", category: "MicAudioCapture")

    init() {
        self.processor = FFTProcessor(fftSize: fftSize, bandCount: bandCount)
    }

    func start() async {
        guard !isCapturing else { return }
        let granted = await Self.requestPermission()
        guard granted else {
            permissionDenied = true
            lastError = "Microphone permission denied."
            return
        }
        permissionDenied = false
        AudioPlaybackManager.shared.startRecordingMode()
        AudioPlaybackManager.shared.activate()
        do {
            try preferBuiltInMic()
            try startEngine()
            isCapturing = true
            lastError = nil
            log.info("MicAudioCapture started")
        } catch {
            lastError = error.localizedDescription
            AudioPlaybackManager.shared.stopRecordingMode()
            log.error("MicAudioCapture start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        AudioPlaybackManager.shared.stopRecordingMode()
        isCapturing = false
        bins = Array(repeating: 0, count: bandCount)
        log.info("MicAudioCapture stopped")
    }

    // MARK: - Internals

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func preferBuiltInMic() throws {
        let session = AVAudioSession.sharedInstance()
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(builtIn)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let bufferSize = AVAudioFrameCount(fftSize)
        let processor = self.processor
        let smoothing = self.smoothing
        let bandCount = self.bandCount
        // The tap fires on a private audio thread; FFT happens there
        // (no contention), and we Task-hop to MainActor only to publish.
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let result = processor.process(buffer: buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var next = self.bins
                if next.count != bandCount {
                    next = Array(repeating: 0, count: bandCount)
                }
                for i in 0..<bandCount {
                    next[i] = smoothing * next[i] + (1 - smoothing) * result[i]
                }
                self.bins = next
            }
        }
        engine.prepare()
        try engine.start()
    }
}

/// Mutable scratch + FFT plan, owned by the audio thread. Marked
/// `@unchecked Sendable` because the AVAudioEngine tap callback is
/// guaranteed to be serial — the engine never fires two callbacks in
/// parallel — so the internal mutation is safe even though Swift's
/// type system can't prove it from first principles.
private final class FFTProcessor: @unchecked Sendable {
    private let fftSize: Int
    private let bandCount: Int
    private let hannWindow: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>?

    private var windowed: [Float]
    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]
    private var bands: [Float]

    init(fftSize: Int, bandCount: Int) {
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.hannWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftSize,
            isHalfWindow: false
        )
        let log2n = vDSP_Length(log2(Double(fftSize)))
        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realParts = [Float](repeating: 0, count: fftSize / 2)
        self.imagParts = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.bands = [Float](repeating: 0, count: bandCount)
    }

    func process(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize, let fft else { return nil }

        // Keep the most recent fftSize samples (audio thread always
        // hands us the last N — but be defensive).
        let offset = frameCount - fftSize
        for i in 0..<fftSize {
            windowed[i] = channel[offset + i] * hannWindow[i]
        }

        // Pack [Float] into a DSPSplitComplex of length fftSize/2.
        // For real-input FFT, vDSP_ctoz treats consecutive sample
        // pairs as (real, imag) — i.e. the Float array is reinterpreted
        // as a DSPComplex array.
        let complexCount = fftSize / 2
        windowed.withUnsafeMutableBufferPointer { winPtr in
            realParts.withUnsafeMutableBufferPointer { realPtr in
                imagParts.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(
                        realp: realPtr.baseAddress!,
                        imagp: imagPtr.baseAddress!
                    )
                    winPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: complexCount
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(complexCount))
                    }
                    fft.transform(input: split, output: &split, direction: .forward)
                    magnitudes.withUnsafeMutableBufferPointer { magPtr in
                        vDSP_zvabs(&split, 1, magPtr.baseAddress!, 1, vDSP_Length(complexCount))
                    }
                }
            }
        }

        // Scale by 1/N to get a reasonable magnitude range.
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(complexCount))

        // Bucket the complexCount bins into bandCount log-spaced bands.
        // Skip bin 0 (DC) — it's mostly mic-offset noise.
        let firstBin = 1
        let lastBin = complexCount - 1
        let logFirst = log10(Float(firstBin))
        let logLast = log10(Float(lastBin))
        for b in 0..<bandCount {
            let from = pow(10, logFirst + (logLast - logFirst) * Float(b) / Float(bandCount))
            let to = pow(10, logFirst + (logLast - logFirst) * Float(b + 1) / Float(bandCount))
            let i0 = max(firstBin, Int(from.rounded(.down)))
            let i1 = max(i0 + 1, min(lastBin, Int(to.rounded(.up))))
            var sum: Float = 0
            for i in i0..<i1 {
                sum += magnitudes[i]
            }
            let avg = sum / Float(i1 - i0)
            // Empirical normalization. Raw vDSP magnitudes after 1/N
            // scaling sit around 0.0001-0.05 for typical music. sqrt
            // spreads the dynamic range and the *20 multiplier lifts
            // quiet passages to a visible range. Clamped to [0, 1].
            bands[b] = min(1.0, sqrt(max(0, avg) * 20))
        }
        return bands
    }
}
