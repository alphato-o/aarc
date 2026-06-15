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
        VStack(spacing: 0) {
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
                Text(formatElapsed(metrics.elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(yellow.opacity(dim))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            }
            .padding(.bottom, 2)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            // 2×2 quadrant grid — each metric gets a big number + small label,
            // filling the whole lower screen. Pace+distance (the decision
            // metrics) on top; effort+burn below.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    quad(formatDistanceValue(metrics.distanceMeters),
                         formatDistanceUnit(metrics.distanceMeters), .white)
                    vline
                    quad(formatPace(metrics.currentPaceSecPerKm), "PACE", green)
                }
                hline
                HStack(spacing: 0) {
                    quad(formatHR(metrics.currentHeartRate), "BPM", .white, heart: true)
                    vline
                    quad("\(Int(metrics.energyKcal))", "CAL", .white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    /// One quadrant: a big centered number (+ optional heart) over a small
    /// caps label, filling its cell.
    @ViewBuilder
    private func quad(_ value: String, _ label: String, _ color: Color, heart: Bool = false) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(color.opacity(dim))
                    .monospacedDigit()
                if heart {
                    Image(systemName: "heart.fill").font(.system(size: 12))
                        .foregroundStyle(.red.opacity(dim)).baselineOffset(1)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.45)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary.opacity(dim))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vline: some View { Rectangle().fill(.white.opacity(0.10)).frame(width: 1) }
    private var hline: some View { Rectangle().fill(.white.opacity(0.10)).frame(height: 1) }

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
