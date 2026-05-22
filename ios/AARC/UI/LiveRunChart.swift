import SwiftUI
import Charts
import AARCKit

/// In-run live telemetry chart. Replaces the kinetic visualizer.
///
/// X-axis: distance in km, auto-scaling through round steps so the
/// chart stays readable from t=0 (first 100m) all the way out to a
/// 50km ultra. Y-axis: dual-series normalized so heart rate (red) and
/// pace (cyan, inverted — faster = taller) share a 0…1 vertical
/// canvas. Each bar = one 100m sample, locked in once recorded.
///
/// The frontier (rightmost bar) pulses softly to convey "you are
/// here, the chart is still growing." Older bars subtly fade-in as
/// they're added so the visual reads as a slowly-painting telemetry
/// trace rather than a sudden jump.
struct LiveRunChart: View {
    let samples: [LiveRunChartSample]
    let liveDistanceMeters: Double
    /// Drawn so the live frontier dot pulses with HR. Optional — if
    /// nil, the dot pulses at a calm idle rate.
    let liveHeartRateBPM: Double?

    /// Auto-scale steps for the X-axis. Picked from a fixed ladder so
    /// the axis snaps to round numbers (1, 2, 5, 10 km, …) instead of
    /// jittering. 50 km is the practical ceiling — anyone running
    /// further can deal with the chart compressing the last bit.
    private static let xAxisSteps: [Double] = [1, 2, 5, 10, 15, 20, 30, 42, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            legendChip(label: "HR", color: hrAccent, range: hrRangeLabel)
            legendChip(label: "Pace", color: paceAccent, range: paceRangeLabel)
            Spacer(minLength: 4)
            Text(String(format: "%.2f km", liveDistanceMeters / 1000))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private func legendChip(label: String, color: Color, range: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2.bold())
                Text(range).font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            // HR bars — left of each bucket position.
            ForEach(samples, id: \.bucketIndex) { sample in
                if let hr = sample.heartRate {
                    BarMark(
                        x: .value("Distance", sample.distanceKm - 0.025),
                        y: .value("HR", normalize(hr, in: hrRange)),
                        width: .fixed(hrBarWidth)
                    )
                    .foregroundStyle(hrGradient)
                    .cornerRadius(2)
                }
            }

            // Pace bars — right of each bucket position. Pace is inverted
            // so a fast bar is TALL (intuitive).
            ForEach(samples, id: \.bucketIndex) { sample in
                if let pace = sample.paceSecPerKm, pace > 0 {
                    BarMark(
                        x: .value("Distance", sample.distanceKm + 0.025),
                        y: .value("Pace", 1 - normalize(pace, in: paceRange)),
                        width: .fixed(paceBarWidth)
                    )
                    .foregroundStyle(paceGradient)
                    .cornerRadius(2)
                }
            }

            // Live frontier marker — pulsing dot at the runner's
            // current distance, plus a faint vertical guide.
            let nowKm = liveDistanceMeters / 1000
            RuleMark(x: .value("Now", nowKm))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(.white.opacity(0.35))

            PointMark(
                x: .value("Now", nowKm),
                y: .value("Live", 0.5)
            )
            .symbol {
                FrontierDot()
            }
        }
        .chartXScale(domain: 0...xMaxKm)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisTick().foregroundStyle(.white.opacity(0.25))
                if let d = value.as(Double.self) {
                    AxisValueLabel {
                        Text(formatKm(d))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: samples.count)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: xMaxKm)
    }

    // MARK: - Scale

    private var xMaxKm: Double {
        let currentKm = liveDistanceMeters / 1000
        for step in Self.xAxisSteps {
            // Step picks the smallest ceiling that gives at least 10%
            // headroom past the runner's current position — so a fresh
            // bar at the right edge isn't visually clipped to the axis.
            if currentKm * 1.1 < step { return step }
        }
        return 50
    }

    private var xAxisValues: [Double] {
        let max = xMaxKm
        // Show 5-6 marks across whatever range we're at.
        let step: Double
        switch max {
        case ...1: step = 0.2
        case ...2: step = 0.5
        case ...5: step = 1
        case ...10: step = 2
        case ...20: step = 5
        case ...42: step = 10
        default: step = 10
        }
        return stride(from: 0, through: max, by: step).map { $0 }
    }

    // MARK: - Bar widths

    private var hrBarWidth: CGFloat { barWidth(for: xMaxKm) }
    private var paceBarWidth: CGFloat { barWidth(for: xMaxKm) }

    /// Bars get visually narrower as the x-axis expands, otherwise the
    /// chart turns into a coloured wall. Empirical pixel widths that
    /// hold up across iPhone sizes.
    private func barWidth(for axisMax: Double) -> CGFloat {
        switch axisMax {
        case ...1: return 8
        case ...2: return 6
        case ...5: return 4
        case ...10: return 3
        case ...20: return 2
        default: return 1.4
        }
    }

    // MARK: - Series ranges

    private var hrRange: (min: Double, max: Double) {
        let values = samples.compactMap(\.heartRate)
        guard !values.isEmpty else { return (60, 180) }
        let lo = values.min() ?? 60
        let hi = values.max() ?? 180
        // Widen the range a touch so the bars don't slam the rails.
        let pad = max(8, (hi - lo) * 0.1)
        return (max(40, lo - pad), hi + pad)
    }

    private var paceRange: (min: Double, max: Double) {
        let values = samples.compactMap(\.paceSecPerKm).filter { $0 > 0 }
        guard !values.isEmpty else { return (4 * 60, 8 * 60) }
        let lo = values.min() ?? 240
        let hi = values.max() ?? 480
        let pad = max(15, (hi - lo) * 0.1)
        return (max(120, lo - pad), hi + pad)
    }

    private var hrRangeLabel: String {
        guard !samples.contains(where: { $0.heartRate != nil }) else {
            return "\(Int(hrRange.min))–\(Int(hrRange.max)) bpm"
        }
        return "—"
    }

    private var paceRangeLabel: String {
        let hasPace = samples.contains(where: { ($0.paceSecPerKm ?? 0) > 0 })
        guard hasPace else { return "—" }
        return "\(formatPaceShort(paceRange.min))–\(formatPaceShort(paceRange.max))"
    }

    private func normalize(_ v: Double, in range: (min: Double, max: Double)) -> Double {
        let span = range.max - range.min
        guard span > 0.0001 else { return 0.5 }
        return min(1, max(0, (v - range.min) / span))
    }

    private func formatKm(_ km: Double) -> String {
        if km < 1 {
            return String(format: "%.1f", km)
        }
        return km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }

    private func formatPaceShort(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm) / 60
        let r = Int(secPerKm) % 60
        return String(format: "%d:%02d", m, r)
    }

    // MARK: - Visual style

    private var hrAccent: Color { Color(red: 1.0, green: 0.35, blue: 0.55) }
    private var paceAccent: Color { Color(red: 0.35, green: 0.85, blue: 1.0) }

    private var hrGradient: LinearGradient {
        LinearGradient(
            colors: [
                hrAccent,
                Color(red: 1.0, green: 0.55, blue: 0.85).opacity(0.55),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
    private var paceGradient: LinearGradient {
        LinearGradient(
            colors: [
                paceAccent,
                Color(red: 0.30, green: 1.0, blue: 0.85).opacity(0.55),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// Pulsing dot painted at the chart frontier so the user reads "this
/// is where you are RIGHT NOW; bars are still growing." A spring
/// SwiftUI animation continuously scales the dot up + down.
private struct FrontierDot: View {
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.6 : 1.0)
                .opacity(pulse ? 0.0 : 0.8)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.yellow, Color.orange],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 8, height: 8)
                .shadow(color: .yellow.opacity(0.7), radius: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

#Preview("Early run, 0.4km") {
    LiveRunChart(
        samples: (0..<4).map {
            LiveRunChartSample(
                bucketIndex: $0,
                heartRate: 130 + Double($0) * 4,
                paceSecPerKm: 360 - Double($0) * 8,
                recordedAt: .now
            )
        },
        liveDistanceMeters: 420,
        liveHeartRateBPM: 148
    )
    .frame(height: 220)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Mid run, 8 km") {
    LiveRunChart(
        samples: (0..<80).map { i in
            LiveRunChartSample(
                bucketIndex: i,
                heartRate: 140 + 25 * sin(Double(i) * 0.1),
                paceSecPerKm: 330 + 30 * sin(Double(i) * 0.07),
                recordedAt: .now
            )
        },
        liveDistanceMeters: 8050,
        liveHeartRateBPM: 162
    )
    .frame(height: 220)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
