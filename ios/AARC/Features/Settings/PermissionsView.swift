import SwiftUI
import UIKit

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
                motionRow
            } footer: {
                Text("HealthKit reads (and writes) your workouts. Microphone and speech recognition power voice notes (Phase 2). Notifications relay the watch handoff. Location is required for phone-only outdoor runs (GPS distance + pace + route). Motion & Fitness is required for phone-only treadmill runs (step count + distance estimate).")
            }
        }
        .navigationTitle("Permissions")
        .task { await manager.refresh() }
    }

    /// Motion & Fitness needs a special affordance: once denied, iOS
    /// won't show the prompt again, ever. The "Request" button stops
    /// being useful and the user has to flip the toggle in Settings
    /// manually. Show "Open Settings" in the denied state so they
    /// can jump straight there.
    @ViewBuilder
    private var motionRow: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Motion & Fitness")
                Text(manager.motionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch manager.motionStatus {
            case .denied, .restricted:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            default:
                Button("Request") {
                    Task { await manager.requestMotion() }
                }
                .buttonStyle(.bordered)
            }
        }
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
