import AppIntents

/// "Hey Siri, tell Control Room" (long press on the earbuds, then the phrase).
///
/// Siri only opens the mic; the app records until he decides it is done
/// (founder, 2026-10-17: Siri's own dictation cut him off mid-sentence).
/// AudioRecordingIntent is what lets a background app start recording.
/// Saying it again while recording sends.
/// LiveActivityIntent too: it is what lets an intent start the required
/// Live Activity while the app is in the background.
struct TellControlRoomIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Tell Control Room"
    static let description = IntentDescription(
        "Record a message for Control Room. Press your earbud, or say \"send to Control Room\", when you're done.")
    static let openAppWhenRun = false

    /// No spoken reply once the mic is open: Siri talking takes the audio
    /// and paused the recorder (device, build 210). The rising tone is the cue.
    @MainActor
    func perform() async throws -> some IntentResult {
        let recorder = ControlRoomRecorder.shared
        if recorder.isRecording {
            await recorder.finish(send: true)
            return .result()
        }
        // The long-press that opened Siri already sent the line; don't
        // start a new recording on the same breath.
        if let t = recorder.lastFinishedAt, Date.now.timeIntervalSince(t) < 10 { return .result() }
        do {
            try recorder.start()
        } catch {
            var detail = error.localizedDescription
            if case ControlRoomRecorder.RecorderError.noLiveActivity(let why) = error { detail += " (\(why))" }
            await ControlRoomChannel.shared.diagNow("talkback intent failed: \(detail)")
            throw error   // nothing is recording, so Siri may say why
        }
        // No speech once the mic is open: Siri talking pauses the recorder.
        return .result()
    }
}

/// "Hey Siri, send to Control Room": the hands-busy way to finish.
struct SendToControlRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Control Room"
    static let description = IntentDescription("Send the message you're recording for Control Room.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlRoomRecorder.shared.isRecording else {
            if let t = ControlRoomRecorder.shared.lastFinishedAt, Date.now.timeIntervalSince(t) < 30 {
                return .result(dialog: "Sent.")
            }
            return .result(dialog: "Nothing to send.")
        }
        await ControlRoomRecorder.shared.finish(send: true)
        return .result(dialog: "Sent.")
    }
}

/// "Hey Siri, cancel Control Room": scrap the recording.
struct CancelControlRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Control Room message"
    static let description = IntentDescription("Throw away the message you're recording for Control Room.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlRoomRecorder.shared.isRecording else { return .result(dialog: "Nothing to cancel.") }
        await ControlRoomRecorder.shared.finish(send: false)
        return .result(dialog: "Scrapped.")
    }
}

/// Phrases Siri accepts with no setup. `\(.applicationName)` also matches the
/// Info.plist alternative names ("Control Room", "Home Base").
struct AARCShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TellControlRoomIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "Talk to \(.applicationName)",
                "Message \(.applicationName)",
                "\(.applicationName) listen",
            ],
            shortTitle: "Tell Control Room",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: SendToControlRoomIntent(),
            phrases: [
                "Send to \(.applicationName)",
                "\(.applicationName) send",
                "Send it to \(.applicationName)",
                "\(.applicationName) done",
                "Done \(.applicationName)",
                "I'm done \(.applicationName)",
                "\(.applicationName) over",
            ],
            shortTitle: "Send to Control Room",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: CancelControlRoomIntent(),
            phrases: [
                "Cancel \(.applicationName)",
                "\(.applicationName) cancel",
            ],
            shortTitle: "Cancel message",
            systemImageName: "xmark"
        )
    }
}
