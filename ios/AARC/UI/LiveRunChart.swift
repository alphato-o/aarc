import SwiftUI
import Charts
import AARCKit

/// In-run live telemetry chart. Replaces the kinetic visualizer.
///
/// X-axis: distance in km, auto-scaling through round steps so the
/// chart stays readable from t=0 (first 100m) all the way out to a
/// 50km ultra. Two normalized bar series share a 0…1 vertical canvas,
/// OVERLAPPED on the same x: a wide translucent speed bar (blue, km/h)
/// behind a narrow solid HR bar (red, bpm), so both heights read
/// independently. A dual y-axis labels km/h on the leading edge and bpm
/// on the trailing edge. HR is watch-only — on a phone-only treadmill
/// run only the speed bars draw.
///
/// The frontier dot pulses at the runner's current position, riding the
/// live speed value so it tracks performance as the bars grow.
struct LiveRunChart: View {
    let samples: [LiveRunChartSample]
    let liveDistanceMeters: Double
    /// Current speed in km/h — positions the live frontier dot
    /// vertically on the speed line. nil when there's no pace reading
    /// (dot falls back to mid-height).
    let liveSpeedKmh: Double?
    /// Current HR — reserved for future use (dot pulse rate). Optional.
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
            legendChip(label: "Speed", color: speedAccent, range: speedRangeLabel)
            if hasHR {
                legendChip(label: "HR", color: hrAccent, range: hrRangeLabel)
            }
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
            // Speed bars (blue) — WIDE and translucent, drawn first so
            // they sit behind. Normalised km/h, so a faster split is
            // taller. One bar per 100m bucket; they march left-to-right
            // as the run grows.
            ForEach(samples, id: \.bucketIndex) { sample in
                if let pace = sample.paceSecPerKm, pace > 0 {
                    BarMark(
                        x: .value("Distance", sample.distanceKm),
                        y: .value("Speed", normalize(3600 / pace, in: speedRange)),
                        width: .fixed(speedBarWidth)
                    )
                    .foregroundStyle(speedAccent.opacity(0.40))
                    .cornerRadius(1.5)
                }
            }

            // HR bars (red) — NARROWER and solid, centered on the SAME x
            // as the speed bar and drawn on top. Because the back bar is
            // wide+translucent and the front bar is narrow+solid, both
            // heights read independently even where they overlap. HR is
            // watch-only — empty on phone-only treadmill, so the chart
            // reads as clean speed-only bars there.
            ForEach(samples, id: \.bucketIndex) { sample in
                if let hr = sample.heartRate {
                    BarMark(
                        x: .value("Distance", sample.distanceKm),
                        y: .value("HR", normalize(hr, in: hrRange)),
                        width: .fixed(hrBarWidth)
                    )
                    .foregroundStyle(hrAccent.opacity(0.95))
                    .cornerRadius(1)
                }
            }

            // Live frontier marker — pulsing dot at the runner's current
            // position, riding the speed value, plus a faint vertical guide.
            let nowKm = liveDistanceMeters / 1000
            RuleMark(x: .value("Now", nowKm))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(.white.opacity(0.35))

            PointMark(
                x: .value("Now", nowKm),
                y: .value("Live", dotY)
            )
            .symbol {
                FrontierDot()
            }
        }
        .chartXScale(domain: 0...xMaxKm)
        .chartYScale(domain: 0...1)
        .chartYAxis {
            // Leading axis labelled km/h (speed). Map normalised tick
            // positions back to real units via the speed range.
            AxisMarks(position: .leading, values: axisTicks) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                if let t = value.as(Double.self) {
                    AxisValueLabel {
                        Text(speedAxisLabel(t))
                            .font(.caption2)
                            .foregroundStyle(speedAccent.opacity(0.8))
                    }
                }
            }
            // Trailing axis labelled bpm (HR) — only when HR is present.
            if hasHR {
                AxisMarks(position: .trailing, values: axisTicks) { value in
                    if let t = value.as(Double.self) {
                        AxisValueLabel {
                            Text(hrAxisLabel(t))
                                .font(.caption2)
                                .foregroundStyle(hrAccent.opacity(0.8))
                        }
                    }
                }
            }
        }
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
        // Hard backstop: clip to the chart frame so a spring overshoot,
        // a fixed-width frontier bar at the edge, or any other transient
        // can never paint outside the container.
        .clipped()
    }

    /// Normalised y for the live frontier dot — rides the speed line.
    private var dotY: Double {
        guard let kmh = liveSpeedKmh else { return 0.5 }
        return normalize(kmh, in: speedRange)
    }

    /// Shared tick positions for both y-axes (normalised 0…1).
    private let axisTicks: [Double] = [0, 0.25, 0.5, 0.75, 1.0]

    private func speedAxisLabel(_ t: Double) -> String {
        let v = speedRange.min + t * (speedRange.max - speedRange.min)
        return v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private func hrAxisLabel(_ t: Double) -> String {
        let v = hrRange.min + t * (hrRange.max - hrRange.min)
        return "\(Int(v))"
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

    /// The wide (background) speed bar. Narrows as the x-axis expands so
    /// the chart doesn't turn into a solid wall on long runs.
    private var speedBarWidth: CGFloat {
        switch xMaxKm {
        case ...1: return 10
        case ...2: return 8
        case ...5: return 5
        case ...10: return 3.5
        case ...20: return 2.4
        default: return 1.6
        }
    }

    /// The narrow (foreground) HR bar — centered on the same x as the
    /// speed bar so it reads as a solid stripe inside the translucent
    /// speed column. Floored so it never vanishes on long runs.
    private var hrBarWidth: CGFloat { max(1, speedBarWidth * 0.46) }

    // MARK: - Series ranges

    private var hasHR: Bool { samples.contains { $0.heartRate != nil } }

    /// Speed range in km/h. Derived from the committed per-bucket pace
    /// samples AND the current live speed, so a surge that hasn't been
    /// bucketed yet (and the live frontier dot) is always inside the
    /// range instead of clamping to the top rail. Padded with 15%
    /// headroom so even the tallest bar leaves visible margin.
    private var speedRange: (min: Double, max: Double) {
        var values = samples.compactMap(\.paceSecPerKm).filter { $0 > 0 }.map { 3600 / $0 }
        if let live = liveSpeedKmh, live > 0 { values.append(live) }
        guard let lo = values.min(), let hi = values.max() else { return (6, 14) }
        let pad = max(0.5, (hi - lo) * 0.15)
        return (Swift.max(0, lo - pad), hi + pad)
    }

    private var hrRange: (min: Double, max: Double) {
        // Include the live HR so a sudden spike stays inside the range
        // (same reasoning as speedRange). 15% headroom off the rails.
        var values = samples.compactMap(\.heartRate)
        if let live = liveHeartRateBPM, live > 0 { values.append(live) }
        guard let lo = values.min(), let hi = values.max() else { return (60, 180) }
        let pad = max(8, (hi - lo) * 0.15)
        return (max(40, lo - pad), hi + pad)
    }

    private var hrRangeLabel: String {
        guard !samples.contains(where: { $0.heartRate != nil }) else {
            return "\(Int(hrRange.min))–\(Int(hrRange.max)) bpm"
        }
        return "—"
    }

    private var speedRangeLabel: String {
        let hasSpeed = samples.contains(where: { ($0.paceSecPerKm ?? 0) > 0 })
        guard hasSpeed else { return "—" }
        let r = speedRange
        return String(format: "%.1f–%.1f km/h", r.min, r.max)
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

    // MARK: - Visual style

    private var hrAccent: Color { Color(red: 1.0, green: 0.35, blue: 0.55) }
    private var speedAccent: Color { Color(red: 0.35, green: 0.85, blue: 1.0) }
}

/// Pulsing dot painted at the chart frontier so the user reads "this
/// is where you are RIGHT NOW; the bars are still growing." A spring
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
        liveSpeedKmh: 10.2,
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
        liveSpeedKmh: 11.4,
        liveHeartRateBPM: 162
    )
    .frame(height: 220)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
