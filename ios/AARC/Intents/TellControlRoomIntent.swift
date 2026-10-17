import AppIntents

/// "Hey Siri, tell Control Room ..." / long-press on the earbuds, then talk.
///
/// Siri does the listening and the dictation (the earbuds' mic, on-device),
/// so nothing here touches the audio session mid-run; the app only receives
/// the text. Runs in the app process without bringing it to the foreground.
struct TellControlRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Control Room"
    static let description = IntentDescription(
        "Send a spoken message to Control Room during a run. Control Room answers in your ear.")
    static let openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: "What do you want to tell Control Room?")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Control Room \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ControlRoomChannel.shared.say(message)
        switch outcome {
        case .sent:
            return .result(dialog: "Sent.")
        case .queued:
            return .result(dialog: "No signal yet. I'll send it when it's back.")
        }
    }
}

/// Phrases Siri accepts without any setup. `\(.applicationName)` resolves to
/// "AARC" or any name in Info.plist `INAlternativeAppNames` ("Control Room",
/// "Home Base"), so "Hey Siri, tell Control Room" works out of the box.
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
    }
}
