import SwiftUI
import AARCKit

/// In-run metrics, Apple-Workout faithful: a hero TIME under a hairline, then
/// evenly-distributed metric rows that fill the WHOLE screen — big left-aligned
/// numbers, right-aligned small-caps unit labels, no wasted bottom space. The
/// signature RunnerBadge is a subtle accent in the time row's corner.
struct WatchMetricsView: View {
    let metrics: LiveMetrics
    let runType: RunType

    private var isPaused: Bool { metrics.state == .paused }
    private var dim: Double { isPaused ? 0.55 : 1.0 }

    private let yellow = Color(red: 0.98, green: 0.83, blue: 0.18)
    private let green = Color(red: 0.36, green: 0.85, blue: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero TIME + brand accent.
            HStack(spacing: 6) {
                RunnerBadge(
                    isRunning: metrics.state == .running,
                    speedMps: speedMps(metrics.currentPaceSecPerKm),
                    cadenceSPM: metrics.cadenceStepsPerMinute,
                    indoor: runType == .treadmill
                )
                if isPaused {
                    Text("PAUSED").font(.system(size: 11, weight: .bold)).foregroundStyle(yellow)
                }
                Spacer(minLength: 0)
                Text("TIME").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            }

            Text(formatElapsed(metrics.elapsed))
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(yellow.opacity(dim))
                .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.top, 3)

            // Secondary metrics, distributed to fill the remaining height.
            Spacer(minLength: 4)
            row(formatDistanceValue(metrics.distanceMeters), formatDistanceUnit(metrics.distanceMeters), .white)
            Spacer(minLength: 4)
            row(formatPace(metrics.currentPaceSecPerKm), "PACE", green)
            Spacer(minLength: 4)
            row(formatHR(metrics.currentHeartRate), "BPM", .white, heart: true)
            Spacer(minLength: 4)
            row("\(Int(metrics.energyKcal))", "CAL", .white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    /// Big value left, small-caps unit pinned right (numbers all left-align).
    @ViewBuilder
    private func row(_ value: String, _ unit: String, _ color: Color, heart: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .foregroundStyle(color.opacity(dim))
                .monospacedDigit()
            if heart {
                Image(systemName: "heart.fill").font(.system(size: 13))
                    .foregroundStyle(.red.opacity(dim)).baselineOffset(1)
            }
            Spacer(minLength: 4)
            Text(unit).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary.opacity(dim))
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }

    // MARK: - Formatting

    private func formatElapsed(_ s: TimeInterval) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    private func formatDistanceValue(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f", m / 1000) : String(format: "%.0f", m)
    }
    private func formatDistanceUnit(_ m: Double) -> String { m >= 1000 ? "KM" : "M" }
    private func formatPace(_ secPerKm: Double?) -> String {
        guard let s = secPerKm, s.isFinite, s > 0 else { return "—" }
        return String(format: "%d'%02d\"", Int(s) / 60, Int(s) % 60)
    }
    private func formatHR(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "—" }
        return "\(Int(bpm))"
    }
    private func speedMps(_ secPerKm: Double?) -> Double {
        guard let s = secPerKm, s.isFinite, s > 0 else { return 0 }
        return 1000.0 / s
    }
}
