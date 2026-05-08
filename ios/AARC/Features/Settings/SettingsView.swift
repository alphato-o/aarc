import SwiftUI

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
                }

                Section("About") {
                    LabeledContent("Version", value: AppVersion.versionString)
                    LabeledContent("API", value: Config.apiBaseURL.absoluteString)
                }
            }
            .navigationTitle("Settings")
        }
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

enum AppVersion {
    static var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
