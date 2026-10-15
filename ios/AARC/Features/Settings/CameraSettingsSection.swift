import SwiftUI

/// Settings: the DJI Osmo that rides along in race mode. Pair it here once
/// (the camera shows a code; allow it on its screen), check the live status,
/// and bench-test start/stop before race day.
struct CameraSettingsSection: View {
    @State private var link = OsmoCameraLink.shared
    @State private var enabled = OsmoCameraLink.isEnabled

    var body: some View {
        Section {
            Toggle("Control the Osmo in race mode", isOn: $enabled)
                .onChange(of: enabled) { _, v in OsmoCameraLink.isEnabled = v }
            LabeledContent("Link", value: stateText)
            if let snap = link.snapshot {
                LabeledContent("Camera", value: snap.model ?? link.knownName ?? "Osmo")
                LabeledContent("Status", value: snap.summary)
            } else if let name = link.knownName {
                LabeledContent("Camera", value: "\(name) (paired)")
            }
            if let err = link.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
            if link.state == .off {
                Button {
                    link.activate()
                } label: {
                    Label(link.isPaired ? "Connect now" : "Pair the camera", systemImage: "camera.badge.ellipsis")
                }
            } else {
                Button("Disconnect") { link.deactivate() }
            }
            if link.state == .connected {
                HStack {
                    Button("Start recording") { link.startRecording() }
                    Spacer()
                    Button("Stop") { link.stopRecording() }
                    Spacer()
                    Button("Video mode") { link.switchToVideo() }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            if link.isPaired {
                Button(role: .destructive) { link.forget() } label: {
                    Label("Forget camera", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("DJI Osmo camera")
        } footer: {
            Text("Race mode starts the recording with the run and keeps it rolling, watches the battery and tells you when to swap. First pairing: turn the camera on, tap Pair, then allow the code on the camera screen.")
        }
    }

    private var stateText: String {
        switch link.state {
        case .off: return "off"
        case .bluetoothOff: return "Bluetooth is off"
        case .scanning: return "looking for the camera…"
        case .connecting: return "connecting…"
        case .handshaking: return "pairing…"
        case .awaitingConfirm: return "allow it on the camera screen"
        case .connected: return "connected"
        case .offline: return "offline, waiting for it"
        case .rejected: return "rejected by the camera"
        }
    }
}
