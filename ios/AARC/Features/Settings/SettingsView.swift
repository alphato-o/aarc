import SwiftUI
import AARCKit

struct SettingsView: View {
    @State private var preferRemoteVoice: Bool = Speaker.shared.preferRemoteVoice
    @State private var spotifyAuth = SpotifyAuth.shared
    @State private var spotifyBusy = false
    @State private var personalContext: PersonalContextStore = PersonalContextStore.shared

    var body: some View {
        NavigationStack {
            Form {
                // ---- Audio (user-facing) ----
                Section {
                    Toggle("Mute companion", isOn: muteBinding)
                    Toggle("Use ElevenLabs voice (premium)", isOn: $preferRemoteVoice)
                        .onChange(of: preferRemoteVoice) { _, v in Speaker.shared.preferRemoteVoice = v }
                    if preferRemoteVoice, let err = RemoteTTS.shared.lastError {
                        Text("Last error: \(err)").font(.caption2).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("ElevenLabs gives the companion a punchy neural voice, cached per line. Falls back to Apple's voice automatically if the network drops.")
                }

                // ---- Spotify (user-facing) ----
                Section {
                    LabeledContent("State", value: spotifyAuth.statusDetail)
                    if let err = spotifyAuth.lastError {
                        Text(err).font(.caption2).foregroundStyle(.orange)
                    }
                    if spotifyAuth.isConnected {
                        Button(role: .destructive) { spotifyAuth.disconnect() } label: {
                            Label("Disconnect Spotify", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            spotifyBusy = true
                            Task { @MainActor in await spotifyAuth.connect(); spotifyBusy = false }
                        } label: {
                            HStack {
                                Label("Connect Spotify", systemImage: "music.note")
                                Spacer(); if spotifyBusy { ProgressView() }
                            }
                        }.disabled(spotifyBusy)
                    }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text("In-run DJ commentary reads only the currently-playing track.")
                }

                // ---- Personal trolls (now edited on the dashboard) ----
                Section {
                    let all = personalContext.allBullets
                    LabeledContent("Facts on file", value: "\(all.count)")
                    if let first = all.first {
                        Text("e.g. \u{201C}\(first.prefix(70))\u{201D}")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Link(destination: URL(string: "https://my.aarun.club")!) {
                        Label("Edit on the dashboard", systemImage: "square.and.pencil")
                    }
                } header: {
                    Text("Personal trolls")
                } footer: {
                    Text("The facts the coaches weave into roasts. Editing moved to my.aarun.club \u{2192} \u{201C}Trolls\u{201D} \u{2014} the long list is impractical to edit on the phone. This device pulls the latest at launch.")
                }

                Section("About") {
                    LabeledContent("Version", value: AppVersion.versionString)
                    LabeledContent("API", value: Config.apiBaseURL.absoluteString)
                }

                Section {
                    NavigationLink {
                        DeveloperSettingsView()
                    } label: {
                        Label("Developer", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    Text("Diagnostics, test tools, API keys, engine state.")
                }
            }
            .navigationTitle("Settings")
            .tint(Theme.link)
        }
    }

    private var muteBinding: Binding<Bool> {
        Binding(get: { AudioPlaybackManager.shared.isMuted },
                set: { AudioPlaybackManager.shared.isMuted = $0 })
    }
}

/// Everything developer / diagnostic — kept out of the everyday Settings.
struct DeveloperSettingsView: View {
    @Environment(PhoneSession.self) private var phoneSession
    @State private var pingResult: String?
    @State private var pinging = false
    @State private var musixmatchKey: String = UserDefaults.standard.string(forKey: "musixmatch.apiKey") ?? ""
    @State private var sentryDSN: String = UserDefaults.standard.string(forKey: CrashReporter.dsnDefaultsKey) ?? ""

    var body: some View {
        Form {
            Section("Tools") {
                NavigationLink("Control Room") { ControlRoomView() }
                NavigationLink("Coach Playground") { CoachPlayground() }
                NavigationLink("Script Preview (AI)") { ScriptPreviewView() }
                NavigationLink("Phone-only / Pedometer") { DiagnosticsView() }
                NavigationLink("Permissions") { PermissionsView() }
            }

            Section("Connectivity tests") {
                Button(action: ping) {
                    HStack {
                        Text("Ping API"); Spacer()
                        if pinging { ProgressView() }
                        else if let pingResult { Text(pingResult).foregroundStyle(.secondary) }
                    }
                }.disabled(pinging)
                Button("Send hello to watch") { phoneSession.sendHello() }
                    .disabled(!phoneSession.isReachable)
                LabeledContent("Watch reachable", value: phoneSession.isReachable ? "Yes" : "No")
                Button("Test companion voice") {
                    Speaker.shared.speak("Right then. Audio test. If your music just ducked and you can hear me, AARC's audio is wired up properly, you marvellous wastrel.")
                }
                LabeledContent("Audio session", value: AudioPlaybackManager.shared.isSessionActive ? "Active" : "Idle")
            }

            Section {
                LabeledContent("Script Engine", value: ScriptEngine.shared.isActive ? "Active" : "Idle")
                LabeledContent("Lines dispatched", value: "\(ScriptEngine.shared.dispatchCount)").monospacedDigit()
                LabeledContent("Contextual Coach", value: ContextualCoach.shared.isRunning ? "Watching" : "Idle")
                if let trigger = ContextualCoach.shared.lastFiredTrigger {
                    LabeledContent("Last trigger", value: trigger).font(.caption)
                }
                if let err = ContextualCoach.shared.lastError {
                    Text("Last error: \(err)").font(.caption2).foregroundStyle(.orange)
                }
            } header: {
                Text("Engine state")
            }

            Section("API keys") {
                SecureField("Sentry DSN", text: $sentryDSN)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: sentryDSN) { _, v in
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.isEmpty { UserDefaults.standard.removeObject(forKey: CrashReporter.dsnDefaultsKey) }
                        else { UserDefaults.standard.set(t, forKey: CrashReporter.dsnDefaultsKey) }
                    }
                SecureField("Musixmatch API key", text: $musixmatchKey)
                    .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: musixmatchKey) { _, v in
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.isEmpty { UserDefaults.standard.removeObject(forKey: "musixmatch.apiKey") }
                        else { UserDefaults.standard.set(t, forKey: "musixmatch.apiKey") }
                    }
                Text(musixmatchKey.isEmpty ? "Musixmatch not set — LRCLib + NetEase + lyrics.ovh only." : "Musixmatch configured.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.link)
    }

    private func ping() {
        pinging = true; pingResult = nil
        Task {
            defer { pinging = false }
            do {
                let r = try await ProxyClient.shared.ping()
                pingResult = r.ok ? "pong (\(r.service))" : "fail"
            } catch { pingResult = "error: \(error.localizedDescription)" }
        }
    }
}
