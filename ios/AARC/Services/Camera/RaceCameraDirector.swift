import Foundation
import Observation

/// Race-mode camera policy (founder, 2026-10-16): the Osmo rolls for the whole
/// session, Home Base reports its state in its own voice, and the battery is
/// watched closely enough that he knows when to swap one of the three spares.
/// Lines are local templates, not LLM calls: a camera report must work with
/// the network gone, and it must say the number, not riff on it.
///
/// Active only while a race-mode run (training or actual) is live; `runEnded`
/// stops the recording and releases the link.
@MainActor
@Observable
final class RaceCameraDirector {
    static let shared = RaceCameraDirector()

    private(set) var isActive = false
    /// What the runner last heard about the camera, for the run screen.
    private(set) var lastReport: String?

    private let link = OsmoCameraLink.shared
    private var wantRecording = false
    private var tick: Task<Void, Never>?
    private var lastStartAttempt = Date.distantPast
    private var lastModeSwitch = Date.distantPast
    private var reportedOffline = false
    private var wasConnected = false
    private var announcedRecording = false
    private var lowestWarned = 101
    private var lastBatteryLogged: Int?
    private var lastTempWarned = 0
    private var cardWarnedMinutes = Int.max
    private var lastKnownRecording = false
    private var stopSentAt: Date?

    func runStarted(raceMode: RaceMode) {
        guard raceMode != .off else { return }
        guard OsmoCameraLink.isEnabled else {
            RunEventLog.shared.record("camera.off", "race mode without camera control (switched off in Settings)")
            return
        }
        isActive = true
        wantRecording = true
        reportedOffline = false
        wasConnected = link.state == .connected
        announcedRecording = false
        lowestWarned = 101
        lastBatteryLogged = nil
        lastTempWarned = 0
        cardWarnedMinutes = Int.max
        stopSentAt = nil
        link.observer = { [weak self] event in self?.handle(event) }
        link.activate()
        RunEventLog.shared.record("camera.director", "armed (\(raceMode.rawValue)); link \(link.state.rawValue)")
        tick?.cancel()
        tick = Task { [weak self] in
            while let self, !Task.isCancelled, self.isActive {
                self.evaluate()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The gate press: note where the race starts inside the footage.
    func gateCrossed() {
        guard isActive else { return }
        let rec = link.snapshot?.recordTimeSec ?? 0
        RunEventLog.shared.record("camera.gate", "race clock starts at \(rec)s into the current clip",
                                  data: ["recordTimeSec": String(rec), "recording": String(link.snapshot?.isRecording ?? false)])
    }

    func runEnded() {
        guard isActive else { return }
        isActive = false
        wantRecording = false
        tick?.cancel(); tick = nil
        let minutes = (link.snapshot?.recordTimeSec ?? 0) / 60
        if link.state == .connected {
            link.stopRecording()
            stopSentAt = .now
            let battery = link.snapshot?.batteryPercent.map { ", battery \($0) percent" } ?? ""
            say("Camera stopped. \(minutes) minutes in the last clip\(battery).", key: "end")
        }
        RunEventLog.shared.record("camera.director", "released; \(link.snapshot?.summary ?? "no status")")
        // Let the stop land before the link goes away.
        Task { [link] in
            try? await Task.sleep(for: .seconds(2))
            link.observer = nil
            link.deactivate()
        }
    }

    /// For the kilometre readout: the few facts Home Base may mention.
    var readoutInfo: AIClient.CameraInfo? {
        guard isActive else { return nil }
        let s = link.snapshot
        return AIClient.CameraInfo(
            connected: link.state == .connected,
            recording: s?.isRecording ?? false,
            batteryPercent: s?.batteryPercent,
            remainMinutes: s?.remainTimeSec.map { $0 / 60 },
            tempOver: s?.tempOver ?? 0)
    }

    // MARK: - Policy

    private func handle(_ event: OsmoCameraLink.Event) {
        switch event {
        case .state(let s):
            RunEventLog.shared.record("camera.link.state", s.rawValue)
            if s == .connected {
                if wasConnected == false, reportedOffline {
                    // Back after a swap or a dropout: say so with the number.
                    let b = link.snapshot?.batteryPercent.map { " at \($0) percent" } ?? ""
                    say("Camera back online\(b). Starting the recording.", key: "back")
                    announcedRecording = false
                }
                reportedOffline = false
                wasConnected = true
                lowestWarned = 101
                lastStartAttempt = .distantPast
            } else if s == .offline || s == .off {
                wasConnected = false
            } else if s == .awaitingConfirm {
                say("Camera is asking for the pairing. Allow it on the camera screen.", key: "confirm")
            } else if s == .rejected {
                say("Camera rejected the pairing. Reset the wireless connection in the camera settings.", key: "rejected")
            }
        case .status(let snap):
            logBattery(snap)
            if snap.isRecording, !announcedRecording {
                announcedRecording = true
                let battery = snap.batteryPercent.map { ", battery \($0) percent" } ?? ""
                say("Camera recording\(battery).", key: "rec")
            }
            if lastKnownRecording, !snap.isRecording, wantRecording, stopSentAt == nil {
                RunEventLog.shared.record("camera.status", "recording stopped by itself")
                announcedRecording = false
            }
            lastKnownRecording = snap.isRecording
            checkBattery(snap)
            checkTemperature(snap)
            checkCard(snap)
        case .ack(let key, let ok):
            if key == "1D03", !ok { say("Camera refused the record command.", key: "nack") }
        }
    }

    private func evaluate() {
        guard isActive else { return }
        let now = Date()
        // Offline for a while: say it once, then wait for it to come back.
        if link.state != .connected, let since = link.disconnectedAt ?? (link.state == .scanning ? link.lastConnectedAt : nil),
           now.timeIntervalSince(since) > 10, !reportedOffline {
            reportedOffline = true
            say("Camera offline. If that is a battery swap, carry on; I restart the recording when it is back.", key: "offline")
        }
        guard link.state == .connected, wantRecording, let snap = link.snapshot else { return }
        guard !snap.isAsleep, snap.tempOver < 2, !snap.isRecording else { return }
        if snap.isVideoMode == false {
            if now.timeIntervalSince(lastModeSwitch) > 6 {
                lastModeSwitch = now
                link.switchToVideo()
                RunEventLog.shared.record("camera.cmd", "switch to video (was \(snap.modeName ?? "?"))")
            }
            return
        }
        if now.timeIntervalSince(lastStartAttempt) > 8, now.timeIntervalSince(snap.updatedAt) < 5 {
            lastStartAttempt = now
            link.startRecording()
            RunEventLog.shared.record("camera.cmd", "start recording")
        }
    }

    private func logBattery(_ snap: OsmoCameraLink.Snapshot) {
        guard let b = snap.batteryPercent else { return }
        if let last = lastBatteryLogged, abs(last - b) < 5, snap.isRecording == lastKnownRecording { return }
        lastBatteryLogged = b
        RunEventLog.shared.record("camera.status", snap.summary,
                                  data: ["battery": String(b), "recording": String(snap.isRecording),
                                         "remainMin": String((snap.remainTimeSec ?? 0) / 60)])
    }

    private func checkBattery(_ snap: OsmoCameraLink.Snapshot) {
        guard let b = snap.batteryPercent else { return }
        // A jump up means a fresh battery went in: re-arm the ladder.
        if let last = lastBatteryLogged, b > last + 20 { lowestWarned = 101 }
        let ladder: [(Int, String)] = [
            (30, "Camera battery thirty percent. About forty minutes of recording left; plan the swap."),
            (20, "Camera at twenty percent. Swap the battery at the next water station. The recording restarts by itself."),
            (10, "Camera at ten percent. Swap it now."),
            (5, "Camera at five percent. It will die in minutes."),
        ]
        for (threshold, line) in ladder where b <= threshold && lowestWarned > threshold {
            lowestWarned = threshold
            say(line, key: "bat\(threshold)")
            break
        }
    }

    private func checkTemperature(_ snap: OsmoCameraLink.Snapshot) {
        if snap.tempOver >= 2, lastTempWarned < snap.tempOver {
            lastTempWarned = snap.tempOver
            say(snap.tempOver >= 3 ? "Camera overheating. It will shut itself down." : "Camera too hot to record. Get it out of the sun.", key: "temp")
        } else if snap.tempOver == 0 { lastTempWarned = 0 }
    }

    private func checkCard(_ snap: OsmoCameraLink.Snapshot) {
        guard let remain = snap.remainTimeSec else { return }
        let minutes = remain / 60
        if minutes <= 15, minutes < cardWarnedMinutes - 4 {
            cardWarnedMinutes = minutes
            say("Camera card has \(minutes) minutes left.", key: "card\(minutes)")
        }
    }

    private func say(_ text: String, key: String) {
        lastReport = text
        RunEventLog.shared.record("camera.say", text, data: ["key": key])
        guard LiveMetricsConsumer.shared.isRunActive || key == "end" else { return }
        Speaker.shared.speak(text, priority: .milestone, source: "home:camera:\(key)", dedupKey: "camera:\(key)",
                             expiresAfter: 120, voiceId: RemoteTTS.homeVoiceId)
    }
}
