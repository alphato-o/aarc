import SwiftUI
import AARCKit

/// Phone-side live readout for the run that's currently happening on the
/// watch. Shows up only when there's an active run; minimal styling. In
/// §1.7 this becomes the proper ActiveRunView with mute/end controls and
/// AI-line history; right now it's a verification surface that the
/// WatchConnectivity stream is alive.
struct LiveRunTile: View {
    @Environment(LiveMetricsConsumer.self) private var consumer

    var body: some View {
        if let metrics = consumer.latest, consumer.isRunActive {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Live run on watch", systemImage: "applewatch.radiowaves.left.and.right")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Spacer()
                    if consumer.isWatchStale {
                        Label("Stale", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if metrics.state == .paused {
                        Text("PAUSED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.yellow.opacity(0.3), in: Capsule())
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(formatElapsed(metrics.elapsed))
                        .font(.system(.title, design: .rounded, weight: .heavy))
                        .monospacedDigit()
                    Spacer()
                    Text(formatDistance(metrics.distanceMeters))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    metric("Pace", value: formatPace(metrics.currentPaceSecPerKm))
                    metric("Avg", value: formatPace(metrics.avgPaceSecPerKm))
                    metric("HR", value: formatHR(metrics.currentHeartRate))
                    metric("kcal", value: "\(Int(metrics.energyKcal))")
                }

                if let split = metrics.lastSplit {
                    HStack {
                        Text("Last km")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("km \(split.kmIndex) · \(formatPace(split.paceSecPerKm))")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
