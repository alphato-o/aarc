import SwiftUI
import AARCKit

/// Live-run view shown after the user taps Start. Reads from
/// `WorkoutSessionHost.liveMetrics` and renders. Computes nothing itself.
struct WatchActiveRunView: View {
    @Environment(WorkoutSessionHost.self) private var host
    @Environment(\.dismiss) private var dismiss

    @State private var showEndConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                modeBadge
                    .padding(.bottom, 2)

                Text(formatElapsed(host.liveMetrics.elapsed))
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .monospacedDigit()

                Text(formatDistance(host.liveMetrics.distanceMeters))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    metric("Pace", value: formatPace(host.liveMetrics.currentPaceSecPerKm))
                    metric("HR", value: formatHR(host.liveMetrics.currentHeartRate))
                }
                .padding(.top, 4)

                if host.state == .paused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if host.state == .running {
                        Button("Pause") { host.pause() }
                            .tint(.yellow)
                    } else if host.state == .paused {
                        Button("Resume") { host.resume() }
                            .tint(.green)
                    }
                    Button("End") { showEndConfirm = true }
                        .tint(.red)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
        }
        .navigationBarBackButtonHidden(true)
        .alert("End run?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("End", role: .destructive) {
                Task {
                    _ = await host.endRun()
                    dismiss()
                }
            }
        } message: {
            Text(host.currentRunIsTestData
                 ? "This is a test run. It will be tagged in Apple Health for easy cleanup."
                 : "This run will be permanently saved to Apple Health.")
        }
    }

    @ViewBuilder
    private var modeBadge: some View {
        let isIndoor = host.currentRunType == .treadmill
        Label(
            isIndoor ? "Treadmill" : "Outdoor",
            systemImage: isIndoor ? "figure.run.treadmill" : "figure.run"
        )
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.25), in: Capsule())
    }

    @ViewBuilder
    private func metric(_ label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func formatPace(_ secPerKm: Double?) -> String {
        guard let s = secPerKm, s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return String(format: "%d:%02d", m, r)
    }

    private func formatHR(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "—" }
        return "\(Int(bpm))"
    }
}
