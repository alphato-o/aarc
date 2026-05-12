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
                permissionRow("Notifications", status: manager.notificationDescription) {
                    Task { await manager.requestNotifications() }
                }
                permissionRow("Location", status: manager.locationDescription) {
                    Task { await manager.requestLocation() }
                }
            } footer: {
                Text("HealthKit reads (and writes) your workouts. Microphone and speech recognition power voice notes (Phase 2). Notifications relay the watch handoff. Location is required for phone-only outdoor runs (GPS distance + pace + route) — same usage Apple Workout uses on the watch.")
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
