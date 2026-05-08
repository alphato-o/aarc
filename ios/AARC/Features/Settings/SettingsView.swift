import SwiftUI
import AARCKit

struct SettingsView: View {
    @Environment(PhoneSession.self) private var phoneSession
    @State private var pingResult: String?
    @State private var pinging = false

    var body: some View {
        NavigationStack {
            Form {
                TestDataSettingsSection()

                Section("Diagnostics") {
                    NavigationLink("Permissions") { PermissionsView() }
                    Button(action: ping) {
                        HStack {
                            Text("Ping API")
                            Spacer()
                            if pinging { ProgressView() }
                            else if let pingResult { Text(pingResult).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(pinging)
                    Button("Send hello to watch") {
                        phoneSession.sendHello()
                    }
                    .disabled(!phoneSession.isReachable)
                    LabeledContent("Watch reachable", value: phoneSession.isReachable ? "Yes" : "No")

                    Button("Test companion voice") {
                        LocalTTS.shared.speak(
                            "Audio test. If your music just ducked, AARC's audio session is wired up. If it kept blasting, something is broken — but at least you have music."
                        )
                    }
                    LabeledContent("Voice", value: LocalTTS.shared.voiceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Audio") {
                    Toggle("Mute companion", isOn: muteBinding)
                    LabeledContent("Audio session", value: AudioPlaybackManager.shared.isSessionActive ? "Active" : "Idle")
                }

                Section("About") {
                    LabeledContent("Version", value: AppVersion.versionString)
                    LabeledContent("API", value: Config.apiBaseURL.absoluteString)
                }
            }
            .navigationTitle("Settings")
        }
    }

    /// Bridges AudioPlaybackManager.isMuted (a non-@Bindable @Observable
    /// property on a singleton) into a SwiftUI Binding for the Toggle.
    private var muteBinding: Binding<Bool> {
        Binding(
            get: { AudioPlaybackManager.shared.isMuted },
            set: { AudioPlaybackManager.shared.isMuted = $0 }
        )
    }

    private func ping() {
        pinging = true
        pingResult = nil
        Task {
            defer { pinging = false }
            do {
                let response = try await ProxyClient.shared.ping()
                pingResult = response.ok ? "pong (\(response.service))" : "fail"
            } catch {
                pingResult = "error: \(error.localizedDescription)"
            }
        }
    }
}

