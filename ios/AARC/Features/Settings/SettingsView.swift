import SwiftUI
import AARCKit

struct SettingsView: View {
    @Environment(PhoneSession.self) private var phoneSession
    @State private var pingResult: String?
    @State private var pinging = false

    @State private var preferRemoteVoice: Bool = Speaker.shared.preferRemoteVoice
    @State private var spotifyAuth = SpotifyAuth.shared
    @State private var spotifyBusy = false
    @State private var musixmatchKey: String = UserDefaults.standard.string(forKey: "musixmatch.apiKey") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Diagnostics") {
                    NavigationLink("Permissions") { PermissionsView() }
                    NavigationLink("Script Preview (AI)") { ScriptPreviewView() }
                    NavigationLink("Coach Playground") { CoachPlayground() }
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
                        Speaker.shared.speak(
                            "Right then. Audio test. If your music just ducked and you can hear me, AARC's audio is wired up properly, you marvellous wastrel."
                        )
                    }
                }

                Section {
                    Toggle("Mute companion", isOn: muteBinding)
                    Toggle("Use ElevenLabs voice (premium)", isOn: $preferRemoteVoice)
                        .onChange(of: preferRemoteVoice) { _, newValue in
                            Speaker.shared.preferRemoteVoice = newValue
                        }

                    if preferRemoteVoice {
                        LabeledContent("ElevenLabs voice", value: RemoteTTS.voiceId)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let err = RemoteTTS.shared.lastError {
                            Text("Last error: \(err)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        LabeledContent("Apple voice", value: LocalTTS.shared.voiceDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Audio session", value: AudioPlaybackManager.shared.isSessionActive ? "Active" : "Idle")
                } header: {
                    Text("Audio")
                } footer: {
                    Text("ElevenLabs gives a punchy neural voice for the companion. Each line is downloaded once and cached on this device — repeats are free. Falls back to Apple's voice automatically if the network drops.")
                }

                Section {
                    LabeledContent("State", value: ScriptEngine.shared.isActive ? "Active" : "Idle")
                    LabeledContent("Lines dispatched", value: "\(ScriptEngine.shared.dispatchCount)")
                        .monospacedDigit()
                    if let last = ScriptEngine.shared.lastDispatched {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last line").font(.caption).foregroundStyle(.secondary)
                            Text(last).font(.caption).lineLimit(3)
                        }
                    }
                } header: {
                    Text("Script Engine")
                } footer: {
                    Text("Activates automatically when the watch starts a workout, using the most-recently generated script in Script Preview. Fires lines as live metrics cross the trigger thresholds.")
                }

                Section {
                    LabeledContent("State", value: ContextualCoach.shared.isRunning ? "Watching" : "Idle")
                    if let trigger = ContextualCoach.shared.lastFiredTrigger,
                       let firedAt = ContextualCoach.shared.lastFiredAt {
                        LabeledContent("Last trigger", value: trigger)
                            .font(.caption)
                        LabeledContent(
                            "Fired",
                            value: relativeTime(since: firedAt)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("No reactive lines fired yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let err = ContextualCoach.shared.lastError {
                        Text("Last error: \(err)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Contextual Coach")
                } footer: {
                    Text("Reactive in-run companion. Watches HR/pace drift and gaps in the script; calls the dynamic-line endpoint with the current run state and injects a fresh one-liner. Shares the global cooldown with scripted lines, so no double-talk.")
                }

                Section {
                    LabeledContent("State", value: spotifyAuth.statusDetail)
                    if let err = spotifyAuth.lastError {
                        Text(err).font(.caption2).foregroundStyle(.orange)
                    }
                    if spotifyAuth.isConnected {
                        Button(role: .destructive) {
                            spotifyAuth.disconnect()
                        } label: {
                            Label("Disconnect Spotify", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            spotifyBusy = true
                            Task { @MainActor in
                                await spotifyAuth.connect()
                                spotifyBusy = false
                            }
                        } label: {
                            HStack {
                                Label("Connect Spotify", systemImage: "music.note")
                                Spacer()
                                if spotifyBusy { ProgressView() }
                            }
                        }
                        .disabled(spotifyBusy)
                    }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text("Used for in-run DJ commentary. AARC reads only the currently-playing track. Redirect URI: aarc://spotify-callback — must match the Spotify Developer Dashboard exactly.")
                }

                Section {
                    SecureField("Musixmatch API key (optional)", text: $musixmatchKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: musixmatchKey) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                UserDefaults.standard.removeObject(forKey: "musixmatch.apiKey")
                            } else {
                                UserDefaults.standard.set(trimmed, forKey: "musixmatch.apiKey")
                            }
                        }
                    if musixmatchKey.isEmpty {
                        Label("Not configured — only LRCLib + lyrics.ovh will be used", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Configured (\(musixmatchKey.count) chars)", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Lyric providers")
                } footer: {
                    Text("DJ commentary needs lyrics. AARC tries LRCLib first (free, synced when available), NetEase if the track has Han characters (free, best Mandopop coverage), then Musixmatch if a key is set (free tier: 2000/day at developer.musixmatch.com — much broader catalog), then lyrics.ovh (free, English-leaning). Cache only stores hits — misses always retry.")
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

    private func relativeTime(since date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "\(elapsed)s ago" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        return "\(elapsed / 3600)h ago"
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

