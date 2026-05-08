import SwiftUI

struct PermissionsView: View {
    @State private var manager = PermissionsManager.shared

    var body: some View {
        Form {
            Section {
                permissionRow("HealthKit", status: manager.healthKitDescription) {
                    Task { await manager.requestHealthKit() }
                }
                permissionRow("Microphone", status: manager.microphoneDescription) {
                    Task { await manager.requestMicrophone() }
                }
                permissionRow("Speech recognition", status: manager.speechDescription) {
                    Task { await manager.requestSpeechRecognition() }
                }
            } footer: {
                Text("AARC needs HealthKit to read workouts written by your Apple Watch and to write companion metadata. Microphone and speech recognition power voice notes (Phase 2).")
            }
        }
        .navigationTitle("Permissions")
        .task { await manager.refresh() }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, status: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Request", action: action)
                .buttonStyle(.bordered)
        }
    }
}
