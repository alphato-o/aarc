import AVFoundation
import UIKit
import ActivityKit
import MediaPlayer
import Observation
import AARCKit

/// Records a line for Control Room after "Hey Siri, tell Control Room".
///
/// Founder, 2026-10-17: Siri's dictation cut him off mid-sentence; out of
/// breath on a run he needs long pauses and wants to decide when to send. So
/// Siri only opens the mic (AudioRecordingIntent) and this records until he
/// says it is done: a press on the earbud, "Hey Siri, send to Control Room",
/// or a very long silence. While recording the app owns Now Playing, which is
/// what routes the earbud press here instead of to Spotify; the music pauses
/// and resumes when the line is sent.
@Observable
@MainActor
final class ControlRoomRecorder: NSObject, AVAudioRecorderDelegate {
    static let shared = ControlRoomRecorder()

    enum RecorderError: LocalizedError {
        case noMicPermission, couldNotStart
        var errorDescription: String? {
            switch self {
            case .noMicPermission: return "AARC has no microphone access. Open the app once to allow it."
            case .couldNotStart: return "Couldn't open the microphone."
            }
        }
    }

    /// Pauses are his to take; only this much silence AFTER speech sends.
    static let silenceSends: TimeInterval = 30
    /// Nothing said at all: drop it rather than send an empty clip.
    static let nothingSaidCancels: TimeInterval = 25
    static let maxSeconds: TimeInterval = 300
    /// averagePower above this counts as speech (earbud mic, dBFS).
    static let speechLevel: Float = -48

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private var recorder: AVAudioRecorder?
    private var clientId = UUID()
    private var meterTimer: Timer?
    private var heardSpeechAt: Date?
    private var activityId: String?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var keepaliveWasRunning = false
    private var runId: String?
    private var km: Double?
    private var runElapsed: Double?
    private var earcon: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var finishing = false
    /// True when the session went non-mixable: the earbud press reaches us.
    private(set) var exclusive = false
    private var startSteps = ""
    private var heals = 0

    private static func code(_ error: Error) -> String {
        let e = error as NSError
        let fourCC: String = {
            let c = UInt32(bitPattern: Int32(truncatingIfNeeded: e.code))
            let bytes = [24, 16, 8, 0].map { UInt8((c >> UInt32($0)) & 0xff) }
            return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? "'" + String(bytes: bytes, encoding: .ascii)! + "'" : ""
        }()
        return "\(e.domain) \(e.code) \(fourCC)"
    }

    private static var foreground: Bool { UIApplication.shared.applicationState == .active }

    static func fileURL(_ id: UUID) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("talkback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id.uuidString).m4a")
    }

    func start() throws {
        guard !isRecording else { return }
        // A background start cannot show the permission prompt.
        guard AVAudioApplication.shared.recordPermission == .granted else { throw RecorderError.noMicPermission }

        let consumer = LiveMetricsConsumer.shared
        runId = consumer.currentRunId?.uuidString
        km = consumer.latest.map { $0.distanceMeters / 1000 }
        runElapsed = consumer.latest?.elapsed
        keepaliveWasRunning = BackgroundAudioKeepalive.shared.isRunning
        VoiceFeedbackQueue.shared.held = true

        let session = AVAudioSession.sharedInstance()
        var steps: [String] = []
        do {
            // A background app may only activate a MIXABLE session (device,
            // build 209: a non-mixable one failed with "session activation
            // failed"). So open the mic mixable first, recording, and only
            // then try to go exclusive (below), which pauses the music and
            // makes the earbud press ours.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothHFP, .mixWithOthers, .duckOthers])
            if let bt = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(bt)
            }
            do {
                try session.setActive(true)
                steps.append("mixable ok")
            } catch {
                steps.append("mixable failed \(Self.code(error))")
                throw error
            }
            clientId = UUID()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: Self.fileURL(clientId), settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else { throw RecorderError.couldNotStart }
            recorder = r
        } catch {
            VoiceFeedbackQueue.shared.held = false
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            AudioPlaybackManager.shared.reassertAfterRecording()
            ControlRoomChannel.shared.diag("talkback start failed: \(steps.joined(separator: ", ")); \(Self.code(error)); fg=\(Self.foreground)")
            throw error
        }
        // Now that we are recording (so, playing audio in the background),
        // try exclusive: music pauses, Now Playing and the earbud press are ours.
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
            exclusive = true
            steps.append("exclusive ok")
        } catch {
            exclusive = false
            steps.append("exclusive refused \(Self.code(error))")
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.allowBluetoothHFP, .mixWithOthers, .duckOthers])
            try? session.setActive(true)
        }
        if recorder?.isRecording != true { recorder?.record() }
        startSteps = steps.joined(separator: ", ")

        isRecording = true
        finishing = false
        startedAt = .now
        heardSpeechAt = nil
        heals = 0
        claimRemoteCommands()
        startActivity()
        observeInterruptions()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if runId != nil { RunEventLog.shared.record("talkback.listening", "") }
        ControlRoomChannel.shared.diag("talkback listening: \(startSteps); activity=\(activityId != nil); fg=\(Self.foreground)")
        // After Siri has finished talking, so the cue is not lost under it.
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if self.isRecording { self.playEarcon(rising: true) }
        }
    }

    /// End the recording; `send: false` throws it away.
    /// `requireSpeech`: the automatic stops only send if speech was heard;
    /// an explicit send (earbud, Siri) always sends.
    func finish(send: Bool, requireSpeech: Bool = false) async {
        guard isRecording, !finishing, let r = recorder else { return }
        finishing = true
        let duration = r.currentTime
        let spoke = heardSpeechAt != nil
        r.stop()
        recorder = nil
        meterTimer?.invalidate(); meterTimer = nil
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
        releaseRemoteCommands()
        playEarcon(rising: false)
        try? await Task.sleep(for: .milliseconds(450))
        isRecording = false

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        AudioPlaybackManager.shared.reassertAfterRecording()
        if keepaliveWasRunning {
            BackgroundAudioKeepalive.shared.stop()
            BackgroundAudioKeepalive.shared.start()
        }
        VoiceFeedbackQueue.shared.held = false

        let url = Self.fileURL(clientId)
        guard send, duration >= 1, spoke || !requireSpeech else {
            try? FileManager.default.removeItem(at: url)
            if runId != nil { RunEventLog.shared.record("talkback.dropped", String(format: "%.0fs", duration)) }
            ControlRoomChannel.shared.diag("talkback dropped: send=\(send) \(String(format: "%.1f", duration))s spoke=\(spoke) heals=\(heals)")
            await endActivity(phase: nil)
            return
        }
        ControlRoomChannel.shared.diag("talkback sending \(String(format: "%.0f", duration))s spoke=\(spoke) heals=\(heals)")
        await updateActivity("sending")
        let outcome = await ControlRoomChannel.shared.sendRecording(
            file: url, clientId: clientId.uuidString, runId: runId, km: km,
            elapsed: runElapsed, duration: duration)
        await endActivity(phase: outcome == .queued ? "queued" : "sent")
    }

    private func tick() {
        guard let r = recorder, isRecording else { return }
        // Siri speaking (or anything else) pauses the recorder and may never
        // post an interruption-ended (device, build 210: the mic sat dead
        // while he talked). Re-arm it ourselves whenever it is not running.
        if !r.isRecording {
            try? AVAudioSession.sharedInstance().setActive(true)
            if r.record() {
                heals += 1
                if heals == 1 { ControlRoomChannel.shared.diag("talkback recorder was paused, resumed at \(String(format: "%.1f", r.currentTime))s") }
            }
            return
        }
        r.updateMeters()
        let now = Date.now
        if r.averagePower(forChannel: 0) > Self.speechLevel { heardSpeechAt = now }
        let elapsed = r.currentTime
        if elapsed >= Self.maxSeconds {
            Task { await finish(send: true, requireSpeech: true) }
        } else if let heard = heardSpeechAt, now.timeIntervalSince(heard) >= Self.silenceSends {
            Task { await finish(send: true, requireSpeech: true) }
        } else if heardSpeechAt == nil, elapsed >= Self.nothingSaidCancels {
            Task { await finish(send: false) }
        }
    }

    // MARK: - Earbud press

    private func claimRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.pauseCommand, center.playCommand,
                        center.nextTrackCommand] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in await self?.finish(send: true) }
                return .success
            }
            commandTargets.append((command, target))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Listening",
            MPMediaItemPropertyArtist: "Control Room",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func releaseRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Siri asking a follow-up, a call, an alarm: the recorder pauses on its
    /// own; carry on recording when the interruption is over.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in
                guard let self, self.isRecording, let r = self.recorder else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                r.record()
            }
        }
    }

    // MARK: - Live Activity (required for a background recording)

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ControlRoomActivityAttributes.ContentState(
            phase: exclusive ? "listening" : "listening-siri", startedAt: startedAt ?? .now)
        activityId = (try? Activity.request(attributes: ControlRoomActivityAttributes(),
                                            content: .init(state: state, staleDate: nil)))?.id
    }

    private func updateActivity(_ phase: String) async {
        guard let id = activityId else { return }
        let content = ActivityContent(state: ControlRoomActivityAttributes.ContentState(
            phase: phase, startedAt: startedAt ?? .now), staleDate: nil)
        await Self.push(id, content)
    }

    private func endActivity(phase: String?) async {
        guard let id = activityId else { return }
        activityId = nil
        let content = ActivityContent(state: ControlRoomActivityAttributes.ContentState(
            phase: phase ?? "sent", startedAt: startedAt ?? .now), staleDate: nil)
        await Self.close(id, content, dismissNow: phase == nil)
    }

    // Looked up by id inside a nonisolated context: Activity is not Sendable.
    private nonisolated static func push(_ id: String,
                                         _ c: ActivityContent<ControlRoomActivityAttributes.ContentState>) async {
        for a in Activity<ControlRoomActivityAttributes>.activities where a.id == id { await a.update(c) }
    }

    private nonisolated static func close(_ id: String,
                                          _ c: ActivityContent<ControlRoomActivityAttributes.ContentState>,
                                          dismissNow: Bool) async {
        for a in Activity<ControlRoomActivityAttributes>.activities where a.id == id {
            await a.end(c, dismissalPolicy: dismissNow ? .immediate : .after(.now.addingTimeInterval(5)))
        }
    }

    // MARK: - Cue tones

    /// Rising pair = mic open, falling pair = sent. Synthesised so there is
    /// no asset to ship.
    private func playEarcon(rising: Bool) {
        let freqs: [Double] = rising ? [660, 990] : [990, 660]
        let rate = 16_000.0, each = 0.11
        var samples: [Int16] = []
        for f in freqs {
            let n = Int(rate * each)
            for i in 0..<n {
                let env = min(1, Double(i) / 160, Double(n - i) / 160)
                samples.append(Int16(sin(2 * .pi * f * Double(i) / rate) * env * 9000))
            }
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        wav.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        wav.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        wav.append("data".data(using: .ascii)!); u32(dataBytes)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        earcon = try? AVAudioPlayer(data: wav)
        earcon?.play()
    }
}
