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
final class ControlRoomRecorder: NSObject {
    static let shared = ControlRoomRecorder()

    enum RecorderError: LocalizedError {
        case noMicPermission, couldNotStart, noLiveActivity(String)
        var errorDescription: String? {
            switch self {
            case .noMicPermission: return "AARC has no microphone access. Open the app once to allow it."
            case .couldNotStart: return "Couldn't open the microphone."
            case .noLiveActivity: return "Couldn't show the recording banner, so I didn't open the mic. Check Live Activities for AARC in Settings."
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
    private var capture: TalkbackCapture?
    /// Live transcript stream for the whole line (all segments). nil = file only.
    private var stream: TalkbackStream?
    private var configObserver: NSObjectProtocol?
    private var notRunningSince: Date?
    private var clientId = UUID()
    private var meterTimer: Timer?
    private var heardSpeechAt: Date?
    private var activityId: String?
    /// The standing banner, started whenever AARC is on screen. iOS refuses a
    /// new Live Activity while the app is already running in the background
    /// ("Target is not foreground", in and after runs, device, 18 Oct), so
    /// talk-back reuses this one.
    private var armedId: String?
    private var foregroundObserver: NSObjectProtocol?
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
    private var inputRoute = ""
    private var speechState = ""
    /// Music was playing when he started: resume it after the send.
    private var otherAudioAtStart = false

    /// Record on the earbuds' mic (HFP). The long-press cannot send then
    /// (call mode), so the stop phrase is the send.
    static let earbudMicKey = "aarc.controlRoom.earbudMic"
    /// Default ON (founder: "in race, iphone mic is too far away from my
    /// voice, won't work. the mic needs to be the powerbeats mic").
    static var useEarbudMic: Bool { UserDefaults.standard.object(forKey: earbudMicKey) as? Bool ?? true }

    private static func recordOptions(mixable: Bool) -> AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if useEarbudMic { o.insert(.allowBluetoothHFP) }
        if mixable { o.formUnion([.mixWithOthers, .duckOthers]) }
        return o
    }

    private static func preferMic(_ session: AVAudioSession) {
        let want: AVAudioSession.Port = useEarbudMic ? .bluetoothHFP : .builtInMic
        if let port = session.availableInputs?.first(where: { $0.portType == want }) {
            try? session.setPreferredInput(port)
        }
    }
    private var heals = 0
    /// One file per uninterrupted stretch. A restart after an interruption
    /// opens a NEW segment; reusing the URL overwrote 150 s of him with a
    /// 0.2 s scrap (device, build 212). Joined into one file at send.
    private var segments: [URL] = []
    private var closedSeconds: TimeInterval = 0
    /// When the last line was handed off. A Siri "send" that arrives just
    /// after the long-press already sent it should still answer "Sent."
    private(set) var lastFinishedAt: Date?
    private var totalSeconds: TimeInterval { closedSeconds + (capture?.seconds ?? 0) }

    private static let recordSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

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

        // The Live Activity FIRST. AppIntents traps the app ("performed with
        // an active audio session but without a Live Activity") if the mic
        // opens without one: that was every crash on builds 209 to 211.
        startedAt = .now
        exclusive = false
        if let reason = startActivity() { throw RecorderError.noLiveActivity(reason) }

        let consumer = LiveMetricsConsumer.shared
        runId = consumer.currentRunId?.uuidString
        km = consumer.latest.map { $0.distanceMeters / 1000 }
        runElapsed = consumer.latest?.elapsed
        keepaliveWasRunning = BackgroundAudioKeepalive.shared.isRunning
        VoiceFeedbackQueue.shared.held = true
        // Keep the line that was playing for after the talk-back, and stop
        // our engine before the category switch: switching under a running
        // engine failed with 'what' on 19 Oct and cut Ricky's opener.
        VoiceFeedbackQueue.shared.interruptCurrent()
        RemoteTTS.shared.resetEngine()
        BackgroundAudioKeepalive.shared.stop()

        let session = AVAudioSession.sharedInstance()
        var steps: [String] = []
        // Since build 229 the run holds the session open between lines. iOS
        // refuses to turn an open session into a recording one from the
        // background ('!int', three talk-backs on the 21 Oct desk test), so
        // close it first; the mixable open below is allowed from background.
        do { try session.setActive(false); steps.append("closed") }
        catch { steps.append("close refused \(Self.code(error))") }
        do {
            // A background app may only activate a MIXABLE session (device,
            // build 209: a non-mixable one failed with "session activation
            // failed"). So open the mic mixable first, recording, and only
            // then try to go exclusive (below), which pauses the music and
            // makes the earbud press ours.
            // Earbud mic (HFP) by default: the only mic near his mouth in a
            // race. It puts the Powerbeats in call mode, where the long-press
            // no longer reaches Siri, so "over and out" is the send.
            try session.setCategory(.playAndRecord, mode: .default, options: Self.recordOptions(mixable: true))
            Self.preferMic(session)
            do {
                try session.setActive(true)
                steps.append("mixable ok")
            } catch {
                steps.append("mixable failed \(Self.code(error))")
                throw error
            }
            clientId = UUID()
            segments = []
            closedSeconds = 0
            if let token = Bundle.main.object(forInfoDictionaryKey: "AARCLiveDeviceToken") as? String, !token.isEmpty {
                stream = TalkbackStream(endpoint: LiveTranscriber.endpoint, token: token)
            }
            guard openSegment() else { throw RecorderError.couldNotStart }
        } catch {
            VoiceFeedbackQueue.shared.held = false
            Task { await endActivity(phase: nil) }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            AudioPlaybackManager.shared.reassertAfterRecording()
            ControlRoomChannel.shared.diag("talkback start failed: \(steps.joined(separator: ", ")); \(Self.code(error)); fg=\(Self.foreground)")
            throw error
        }
        // Now that we are recording (so, playing audio in the background),
        // try exclusive: music pauses, Now Playing and the earbud press are ours.
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.recordOptions(mixable: false))
            try session.setActive(true)
            exclusive = true
            steps.append("exclusive ok")
        } catch {
            exclusive = false
            steps.append("exclusive refused \(Self.code(error))")
            try? session.setCategory(.playAndRecord, mode: .default, options: Self.recordOptions(mixable: true))
            try? session.setActive(true)
        }
        Self.preferMic(session)
        inputRoute = session.currentRoute.inputs.first.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "none"
        steps.append("in=\(inputRoute)")
        otherAudioAtStart = session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
        // The category switch above reconfigures the input; start a fresh
        // segment on the settled route (the first one is a few ms long).
        closeSegment(); _ = openSegment()
        startSteps = steps.joined(separator: ", ")

        isRecording = true
        finishing = false
        heardSpeechAt = nil
        heals = 0
        lastPartialSent = ""
        lastPartialAt = .distantPast
        claimRemoteCommands()
        if !exclusive { Task { await updateActivity("listening-siri") } }
        lastFinishedAt = nil
        PhoneSession.shared.sendBestEffort(.talkbackState(listening: true))
        // Music stays on under his voice by choice (founder, 2026-10-17: "I
        // can talk over the music"); iOS ducks it.
        observeInterruptions()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if runId != nil { RunEventLog.shared.record("talkback.listening", "") }
        ControlRoomChannel.shared.diag("talkback listening: \(startSteps); speech=\(speechState); activity=\(activityId != nil); fg=\(Self.foreground)")
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
        guard isRecording, !finishing else { return }
        finishing = true
        // Keep the process alive through join + upload: once the mic closes
        // nothing else holds the app awake (build 213: the 111 s line never
        // arrived; the app was suspended before the upload).
        let bg = UIApplication.shared.beginBackgroundTask(withName: "talkback-send")
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        PhoneSession.shared.sendBestEffort(.talkbackState(listening: false))
        if otherAudioAtStart { resumeMusicSoon() }
        lastFinishedAt = .now
        closeSegment()
        let duration = closedSeconds
        let spoke = heardSpeechAt != nil
        meterTimer?.invalidate(); meterTimer = nil
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
        releaseRemoteCommands()
        playEarcon(rising: false)
        try? await Task.sleep(for: .milliseconds(450))
        isRecording = false

        // Off the main thread: a deactivate during a Bluetooth route change can
        // block for seconds, and on the main actor that froze the app (18 Oct).
        let deactivateError = await Task.detached { () -> NSError? in
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); return nil }
            catch { return error as NSError }
        }.value
        let deactivate = deactivateError.map { Self.code($0) } ?? "ok"
        AudioPlaybackManager.shared.reassertAfterRecording()
        // The earbuds take a moment to leave call mode; a line started before
        // that lands on the dying route and stalls (the 18 Oct silent replies).
        let settled = await Self.waitForMediaRoute(timeout: 2.5)
        if keepaliveWasRunning || BackgroundAudioKeepalive.shared.wanted {
            BackgroundAudioKeepalive.shared.stop()
            BackgroundAudioKeepalive.shared.start()
        }
        VoiceFeedbackQueue.shared.held = false
        let session = AVAudioSession.sharedInstance()
        ControlRoomChannel.shared.diag("talkback handback: deactivate=\(deactivate) settled=\(settled) cat=\(session.category.rawValue) out=\(session.currentRoute.outputs.first?.portType.rawValue ?? "none")")

        let url = Self.fileURL(clientId)
        guard send, duration >= 1, spoke || !requireSpeech else {
            stream?.cancel(); stream = nil
            segments.forEach { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: url)
            if runId != nil { RunEventLog.shared.record("talkback.dropped", String(format: "%.0fs", duration)) }
            ControlRoomChannel.shared.diag("talkback dropped: send=\(send) \(String(format: "%.1f", duration))s spoke=\(spoke) heals=\(heals)")
            await endActivity(phase: nil)
            return
        }
        // Tier 1: the live transcript, ready now. Tier 2 (nil): the file upload.
        let liveStream = stream
        stream = nil
        let streamedText = await liveStream?.finish()
        let joined = await Self.join(segments, into: url)
        ControlRoomChannel.shared.diag("talkback sending \(String(format: "%.0f", duration))s in \(segments.count) segment(s), join=\(joined), stream=\(streamedText != nil ? "used (\(liveStream?.packets ?? 0) packets)" : "fallback \(liveStream?.state ?? "none")")")
        await updateActivity("sending")
        let outcome = await ControlRoomChannel.shared.sendRecording(
            file: url, clientId: clientId.uuidString, runId: runId, km: km,
            elapsed: runElapsed, duration: duration, startedAt: startedAt ?? .now,
            streamedText: streamedText)
        await endActivity(phase: outcome == .queued ? "queued" : "sent")
    }

    /// Polls until no output is the Bluetooth call (HFP) route.
    private static func waitForMediaRoute(timeout: TimeInterval) async -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            let outs = AVAudioSession.sharedInstance().currentRoute.outputs
            if !outs.contains(where: { $0.portType == .bluetoothHFP }) {
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private var lastPartialSent = ""
    private var lastPartialAt = Date.distantPast

    /// Forward the words so far to the agent every 1.5 s while he talks, so
    /// the Control Room screen shows the line as it is spoken.
    private func forwardPartial() {
        guard let text = stream?.currentText, !text.isEmpty, text != lastPartialSent,
              Date.now.timeIntervalSince(lastPartialAt) >= 1.5 else { return }
        lastPartialSent = text
        lastPartialAt = .now
        let cid = clientId.uuidString, rid = runId
        Task { await AIClient.shared.agentPartial(clientId: cid, text: text, runId: rid) }
    }

    private func tick() {
        guard isRecording, !finishing else { return }
        forwardPartial()
        // Siri, a call: the interruption observer sends. If the engine just
        // stops with no notice, give a route change 3 s to restart it, then
        // send what we have rather than sit on a dead mic.
        guard let c = capture, c.isRunning else {
            if notRunningSince == nil { notRunningSince = .now }
            if let t = notRunningSince, Date.now.timeIntervalSince(t) > 3 {
                ControlRoomChannel.shared.diag("talkback mic stopped at \(String(format: "%.1f", totalSeconds))s, sending")
                Task { await finish(send: true) }
            }
            return
        }
        notRunningSince = nil
        let now = Date.now
        if c.currentLevel > Self.speechLevel { heardSpeechAt = now }
        let elapsed = totalSeconds
        if elapsed >= Self.maxSeconds {
            Task { await finish(send: true, requireSpeech: true) }
        } else if let heard = heardSpeechAt, now.timeIntervalSince(heard) >= Self.silenceSends {
            Task { await finish(send: true, requireSpeech: true) }
        } else if heardSpeechAt == nil, elapsed >= Self.nothingSaidCancels {
            Task { await finish(send: false) }
        }
    }

    /// Siri (the long-press) pauses the music app and does not always give
    /// it back. If it is still quiet after Siri has had its moment, ask
    /// Spotify to resume through the connected account.
    private func resumeMusicSoon() {
        Task {
            // Only Siri pauses it (the side-button send); wait for Siri first.
            for delay in [5.0, 12.0] {
                try? await Task.sleep(for: .seconds(delay))
                let session = AVAudioSession.sharedInstance()
                if session.isOtherAudioPlaying { return }
                guard SpotifyAuth.shared.isConnected else {
                    ControlRoomChannel.shared.diag("talkback: music still paused, Spotify not connected")
                    return
                }
                do {
                    try await SpotifyClient.shared.resume()
                    ControlRoomChannel.shared.diag("talkback: resumed Spotify after \(Int(delay))s")
                    return
                } catch {
                    ControlRoomChannel.shared.diag("talkback: Spotify resume failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Segments

    private func openSegment() -> Bool {
        let url = Self.fileURL(clientId).deletingPathExtension()
            .appendingPathExtension("seg\(segments.count).m4a")
        let c = TalkbackCapture()
        let live = stream
        c.onBuffer = { buf in live?.feed(buf) }
        c.onStopPhrase = {
            Task { @MainActor in
                let me = ControlRoomRecorder.shared
                guard me.isRecording, !me.finishing else { return }
                ControlRoomChannel.shared.diag("talkback: heard \"over and out\" at \(String(format: "%.1f", me.totalSeconds))s, sending")
                await me.finish(send: true)
            }
        }
        do { try c.start(writingTo: url) } catch {
            ControlRoomChannel.shared.diag("talkback segment failed: \(error.localizedDescription)")
            return false
        }
        capture = c
        segments.append(url)
        speechState = c.speechState
        // A route change stops the engine; carry on in a new segment.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: c.engine, queue: .main
        ) { _ in
            Task { @MainActor in
                let me = ControlRoomRecorder.shared
                guard me.isRecording, !me.finishing else { return }
                me.closeSegment()
                _ = me.openSegment()
            }
        }
        return true
    }

    private func closeSegment() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        guard let c = capture else { return }
        closedSeconds += c.seconds
        c.stop()
        capture = nil
    }

    /// Concatenate the segments into `out`. False keeps the longest segment
    /// as `out` instead, so something always goes.
    nonisolated static func join(_ parts: [URL], into out: URL) async -> Bool {
        let fm = FileManager.default
        let existing = parts.filter { fm.fileExists(atPath: $0.path) }
        try? fm.removeItem(at: out)
        guard !existing.isEmpty else { return false }
        if existing.count == 1 {
            try? fm.moveItem(at: existing[0], to: out)
            return true
        }
        let comp = AVMutableComposition()
        var ok = false
        if let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var cursor = CMTime.zero
            for u in existing {
                let asset = AVURLAsset(url: u)
                guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                      let dur = try? await asset.load(.duration), dur > .zero else { continue }
                if (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: cursor)) != nil {
                    cursor = cursor + dur
                }
            }
            if cursor > .zero, let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) {
                ok = (try? await export.export(to: out, as: .m4a)) != nil
            }
        }
        if !ok {
            let sized = existing.map { ($0, (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) }
            if let biggest = sized.max(by: { $0.1 < $1.1 })?.0 { try? fm.copyItem(at: biggest, to: out) }
        }
        existing.forEach { try? fm.removeItem(at: $0) }
        return ok
    }

    // MARK: - Earbud press

    private func claimRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.pauseCommand, center.playCommand,
                        center.nextTrackCommand] {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: Self.remoteHandler())))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Listening",
            MPMediaItemPropertyArtist: "Control Room",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    /// Built outside the main actor on purpose: MediaPlayer calls it on its
    /// own queue, and a main-actor closure there is a runtime isolation trap.
    private nonisolated static func remoteHandler()
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in await ControlRoomRecorder.shared.finish(send: true) }
            return .success
        }
    }

    private func releaseRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Siri asking a follow-up, a call, an alarm: the recorder pauses on its
    /// own; carry on recording when the interruption is over.
    /// Siri (the earbud long-press), a call, an alarm: the interruption is
    /// the send button.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                let me = ControlRoomRecorder.shared
                guard me.isRecording, !me.finishing else { return }
                ControlRoomChannel.shared.diag("talkback interruption began at \(String(format: "%.1f", me.totalSeconds))s, sending")
                await me.finish(send: true)
            }
        }
    }

    // MARK: - Live Activity (required for a background recording)

    /// nil on success, else why it failed.
    private func startActivity() -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return "Live Activities are off for AARC" }
        let state = ControlRoomActivityAttributes.ContentState(phase: "listening", startedAt: startedAt ?? .now)
        if let id = armedId, Self.exists(id) {
            activityId = id
            Task { await Self.push(id, .init(state: state, staleDate: nil)) }
            return nil
        }
        armedId = nil
        do {
            activityId = try Activity.request(attributes: ControlRoomActivityAttributes(),
                                              content: .init(state: state, staleDate: nil)).id
            return nil
        } catch {
            activityId = nil
            // The run's own banner is a Live Activity of this app too.
            if !Activity<LiveActivityAttributes>.activities.isEmpty {
                ControlRoomChannel.shared.diag("talkback: own banner refused (\(Self.code(error))), riding the run banner")
                return nil
            }
            return "\(error.localizedDescription) [\(Self.code(error))]"
        }
    }

    // MARK: - Standing banner

    /// Called at launch, at run start, and whenever AARC comes to the screen.
    func arm() {
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in ControlRoomRecorder.shared.arm() }
            }
        }
        if let id = armedId, Self.exists(id) { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ControlRoomActivityAttributes.ContentState(phase: "ready", startedAt: .now)
        do {
            armedId = try Activity.request(attributes: ControlRoomActivityAttributes(),
                                           content: .init(state: state, staleDate: nil)).id
        } catch {
            armedId = nil
            if Self.foreground {
                ControlRoomChannel.shared.diag("talkback: could not arm the banner: \(Self.code(error))")
            }
        }
    }

    private nonisolated static func exists(_ id: String) -> Bool {
        Activity<ControlRoomActivityAttributes>.activities.contains { $0.id == id && $0.activityState == .active }
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
        if id == armedId {
            // Keep the standing banner: show the outcome, then back to ready.
            if let phase { await Self.push(id, .init(state: .init(phase: phase, startedAt: .now), staleDate: nil)) }
            Task {
                try? await Task.sleep(for: .seconds(phase == nil ? 0 : 6))
                let me = ControlRoomRecorder.shared
                guard me.armedId == id, !me.isRecording else { return }
                await Self.push(id, .init(state: .init(phase: "ready", startedAt: .now), staleDate: nil))
            }
            return
        }
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
