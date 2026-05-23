import WidgetKit
import SwiftUI
import AARCKit

/// Home-screen widget showing the runner's most recent completed run.
/// Styled after Nike Run Club's "Last Run" widget — black canvas,
/// hero distance number, three secondary stats, and (on medium) a
/// per-km pace sparkline so the user can see how the run shaped up
/// without opening the app.
///
/// Data flows from the main AARC app via the App Group container —
/// see `LastRunSnapshot` in AARCKit. The main app writes a fresh
/// snapshot at the end of every run and calls
/// `WidgetCenter.shared.reloadAllTimelines()` so this widget
/// re-renders within a second of the run landing in History.
struct LastRunWidget: Widget {
    let kind: String = "club.aarun.AARC.LastRunWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LastRunProvider()) { entry in
            LastRunWidgetView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Last Run")
        .description("Your most recent AARC run — distance, time, and pace at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Timeline

struct LastRunEntry: TimelineEntry {
    let date: Date
    let snapshot: LastRunSnapshot?
}

struct LastRunProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastRunEntry {
        LastRunEntry(date: .now, snapshot: LastRunSnapshot.preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (LastRunEntry) -> Void) {
        let snap = context.isPreview ? LastRunSnapshot.preview : LastRunSnapshot.load()
        completion(LastRunEntry(date: .now, snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastRunEntry>) -> Void) {
        let snap = LastRunSnapshot.load()
        let entry = LastRunEntry(date: .now, snapshot: snap)
        // Refresh hourly as a baseline — the main app calls
        // WidgetCenter.reloadAllTimelines() the instant a new run lands
        // so the user doesn't have to wait for the next hourly tick to
        // see today's run.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - View

struct LastRunWidgetView: View {
    let snapshot: LastRunSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snap = snapshot {
            switch family {
            case .systemSmall: small(snap)
            case .systemMedium: medium(snap)
            default: medium(snap)
            }
        } else {
            empty
        }
    }

    // MARK: - Small

    private func small(_ snap: LastRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(snap, compact: true)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatDistanceHero(snap.distanceMeters))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("KM")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 6)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(formatDuration(snap.durationSeconds))
                Text("·")
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(formatPace(snap.avgPaceSecPerKm))/km")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.78))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium

    /// NRC-inspired layout: stats row at the top (date + distance +
    /// avg pace), then a tall chart with labeled X+Y axes and per-km
    /// vertical gridlines owning the bottom ~70% of the widget. The
    /// header row ("LAST RUN" + duplicate date) is gone — its slot is
    /// reclaimed by the chart.
    private func medium(_ snap: LastRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statsRow(snap)
            chartArea(snap)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Three-column stats: date subtitle on the left, distance number
    /// in the centre, avg pace on the right. Numbers are italic, sized
    /// so they read as confident headlines without dominating the widget.
    private func statsRow(_ snap: LastRunSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.startedAt, format: .dateTime.month().day().year())
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
                Text(runTypeLabel(snap))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 0) {
                Text(formatDistanceHero(snap.distanceMeters))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .italic()
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("Kilometres")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(formatPaceFancy(snap.avgPaceSecPerKm))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .italic()
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("Avg. Pace")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// "Morning Run / Afternoon Run / Evening Run" + run-type suffix,
    /// matching NRC's "Thursday Morning Run" header but more compact.
    private func runTypeLabel(_ snap: LastRunSnapshot) -> String {
        let hour = Calendar.current.component(.hour, from: snap.startedAt)
        let phase: String
        switch hour {
        case 4..<11: phase = "Morning"
        case 11..<14: phase = "Midday"
        case 14..<18: phase = "Afternoon"
        case 18..<22: phase = "Evening"
        default: phase = "Night"
        }
        let kind = snap.runTypeRaw == "treadmill" ? "Treadmill" : "Run"
        return "\(phase) \(kind)"
    }

    @ViewBuilder
    private func chartArea(_ snap: LastRunSnapshot) -> some View {
        // Prefer fine (per-100m) arrays when available — they give
        // ~10× the resolution of the per-km splits and the chart line
        // reads smooth instead of polygonal. Fall back to per-km
        // splits if a snapshot was written before the fine arrays
        // existed.
        if let pace = snap.paceFine, pace.count >= 2 {
            splitsChart(
                pace: pace,
                hr: snap.hrFine,
                bucketMeters: 100,
                totalDistanceMeters: snap.distanceMeters
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
        } else if let pace = snap.paceSplits, pace.count >= 2 {
            splitsChart(
                pace: pace,
                hr: snap.hrSplits,
                bucketMeters: 1000,
                totalDistanceMeters: snap.distanceMeters
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
        } else {
            VStack {
                Spacer()
                Text("Chart populates after the next run with HealthKit data.")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pieces

    private func header(_ snap: LastRunSnapshot, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: snap.runTypeRaw == "treadmill" ? "figure.run.treadmill" : "figure.run")
                .font(.system(size: compact ? 11 : 13, weight: .heavy))
                .foregroundStyle(accent)
            Text(compact ? "LAST RUN" : "LAST RUN")
                .font(.system(size: compact ? 10 : 11, weight: .heavy, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(accent)
            Spacer(minLength: 4)
            Text(snap.startedAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    /// Dual-line chart with labeled X+Y axes and vertical gridlines
    /// at each km — NRC-style. Pace (sage green) is the primary
    /// series and its bounds appear on the Y axis. HR (pink-red)
    /// rides along normalised to its own range.
    ///
    /// Pace is INVERTED (fastest plots at the top) so the line
    /// visually agrees with intuition: "going faster = going up."
    ///
    /// `bucketMeters` is the distance each entry in `pace`/`hr`
    /// represents — 100 for the fine series, 1000 for the legacy
    /// per-km splits. `totalDistanceMeters` is the run's real total
    /// distance; the X axis spans 0 → totalDistanceMeters so partial
    /// final buckets are still drawn against the right edge of the
    /// plot, and km gridlines land at their accurate positions
    /// regardless of bucket count.
    private func splitsChart(
        pace: [Double],
        hr: [Double]?,
        bucketMeters: Double,
        totalDistanceMeters: Double
    ) -> some View {
        let yLabelWidth: CGFloat = 32
        let xLabelHeight: CGFloat = 14

        let validPace = pace.filter { $0 > 0 }
        let paceMin = validPace.min() ?? 0
        let paceMax = validPace.max() ?? 0

        return ZStack(alignment: .topLeading) {
            // Y axis labels — pace bounds. Fastest at top (inverted),
            // slowest at bottom.
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatPaceFancy(paceMin))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                Text(formatPaceFancy(paceMax))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: yLabelWidth - 4, alignment: .trailing)
            .padding(.bottom, xLabelHeight)

            Canvas { ctx, size in
                let plotW = size.width - yLabelWidth
                let plotH = size.height - xLabelHeight
                guard plotW > 0, plotH > 0, totalDistanceMeters > 0 else { return }
                let xOrigin = yLabelWidth
                let totalKm = Int(floor(totalDistanceMeters / 1000))

                // Vertical gridlines at every COMPLETED km boundary
                // (1km, 2km, …). The partial tail past the last km
                // boundary plots without a gridline behind it.
                let lineColor = Color.white.opacity(0.12)
                if totalKm >= 1 {
                    for k in 1...totalKm {
                        let xRatio = CGFloat(k) * 1000.0 / CGFloat(totalDistanceMeters)
                        let x = xOrigin + xRatio * plotW
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: plotH))
                        ctx.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                    }
                }
                // Horizon line.
                var base = Path()
                base.move(to: CGPoint(x: xOrigin, y: plotH))
                base.addLine(to: CGPoint(x: xOrigin + plotW, y: plotH))
                ctx.stroke(base, with: .color(Color.white.opacity(0.18)), lineWidth: 0.6)

                // Pace line — sage green, inverted.
                drawSeries(
                    ctx: &ctx,
                    origin: CGPoint(x: xOrigin, y: 0),
                    plotSize: CGSize(width: plotW, height: plotH),
                    values: pace,
                    bucketMeters: bucketMeters,
                    totalDistanceMeters: totalDistanceMeters,
                    normalize: { vs, v in
                        let valid = vs.filter { $0 > 0 }
                        guard let lo = valid.min(), let hi = valid.max(), hi > lo else { return 0.5 }
                        return 1.0 - (v - lo) / (hi - lo)
                    },
                    color: accent,
                    lineWidth: bucketMeters <= 200 ? 1.6 : 2.0
                )
                // HR line — pink/red. Only renders when present.
                if let hr, hr.contains(where: { $0 > 0 }) {
                    drawSeries(
                        ctx: &ctx,
                        origin: CGPoint(x: xOrigin, y: 0),
                        plotSize: CGSize(width: plotW, height: plotH),
                        values: hr,
                        bucketMeters: bucketMeters,
                        totalDistanceMeters: totalDistanceMeters,
                        normalize: { vs, v in
                            let valid = vs.filter { $0 > 0 }
                            guard let lo = valid.min(), let hi = valid.max(), hi > lo else { return 0.5 }
                            return (v - lo) / (hi - lo)
                        },
                        color: hrColor,
                        lineWidth: bucketMeters <= 200 ? 1.3 : 1.6
                    )
                }
            }

            xAxisLabels(
                totalDistanceMeters: totalDistanceMeters,
                yLabelWidth: yLabelWidth,
                xLabelHeight: xLabelHeight
            )
        }
    }

    /// Bottom-anchored row of "1km, 2km, …" labels, positioned at the
    /// exact x coordinate where each km boundary lives within the
    /// run's TOTAL distance (not within the bucket array). For runs
    /// longer than 7 km we skip every other label up to 14 km, then
    /// every 5 km, so neighbours don't collide.
    private func xAxisLabels(
        totalDistanceMeters: Double,
        yLabelWidth: CGFloat,
        xLabelHeight: CGFloat
    ) -> some View {
        let totalKm = Int(floor(totalDistanceMeters / 1000))
        let step: Int = {
            if totalKm <= 7 { return 1 }
            if totalKm <= 14 { return 2 }
            return 5
        }()
        return GeometryReader { geo in
            let plotW = geo.size.width - yLabelWidth
            ForEach(1...max(1, totalKm), id: \.self) { k in
                if k <= totalKm, k % step == 0 {
                    Text("\(k)km")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                        .frame(width: 32, alignment: .center)
                        .position(
                            x: yLabelWidth + CGFloat(k) * 1000.0 / CGFloat(totalDistanceMeters) * plotW,
                            y: geo.size.height - xLabelHeight / 2
                        )
                }
            }
        }
    }

    /// Plot one series as a polyline. Each entry maps to the CENTRE
    /// of its bucket (bucketStart + bucketMeters/2). X is computed
    /// against the run's TOTAL distance so a partial last bucket
    /// still anchors correctly within the plot, and the line extends
    /// to the right edge when the run ended mid-km.
    ///
    /// Skips entries with value 0 — gaps render as separate segments
    /// rather than the line diving to the floor.
    private func drawSeries(
        ctx: inout GraphicsContext,
        origin: CGPoint,
        plotSize: CGSize,
        values: [Double],
        bucketMeters: Double,
        totalDistanceMeters: Double,
        normalize: ([Double], Double) -> Double,
        color: Color,
        lineWidth: CGFloat
    ) {
        guard values.count >= 2, totalDistanceMeters > 0 else { return }
        var path = Path()
        var penDown = false
        for (i, v) in values.enumerated() {
            guard v > 0 else { penDown = false; continue }
            let bucketStart = Double(i) * bucketMeters
            // For the final partial bucket, the centre is half the
            // remaining distance rather than half of bucketMeters.
            let bucketEnd = min(Double(i + 1) * bucketMeters, totalDistanceMeters)
            let centre = (bucketStart + bucketEnd) / 2
            let xRatio = centre / totalDistanceMeters
            let x = origin.x + CGFloat(xRatio) * plotSize.width
            let yUnit = normalize(values, v)
            let y = origin.y + plotSize.height * (1 - CGFloat(yUnit))
            if penDown {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                penDown = true
            }
        }
        ctx.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
        // Soft glow underneath.
        ctx.addFilter(.blur(radius: 2.5))
        ctx.stroke(
            path,
            with: .color(color.opacity(0.45)),
            style: StrokeStyle(lineWidth: lineWidth + 1.5, lineCap: .round)
        )
    }

    private var hrColor: Color {
        Color(red: 1.0, green: 0.35, blue: 0.50)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST RUN")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(accent)
            Spacer(minLength: 0)
            Text("No runs yet.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            Text("Open AARC and start one.")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accent: Color {
        // Bright sage green — readable on the all-black widget canvas
        // while staying in the same family as the in-app brand colour
        // (#38503a, which is too dark to read on black on its own).
        Color(red: 0.482, green: 0.682, blue: 0.498)
    }

    // MARK: - Formatting

    private func formatDistanceHero(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f", meters / 1000)
        }
        return String(format: "%.0fm", meters)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatPace(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm) / 60
        let r = Int(secPerKm) % 60
        return String(format: "%d:%02d", m, r)
    }

    /// NRC-style M'SS" format ("6'17\"") — used in the stats row and
    /// the chart's Y-axis labels. Designed to be readable at a glance
    /// at small sizes.
    private func formatPaceFancy(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm) / 60
        let r = Int(secPerKm) % 60
        return "\(m)'\(String(format: "%02d", r))\""
    }

    private func formatKcal(_ kcal: Double) -> String {
        guard kcal.isFinite else { return "—" }
        return "\(Int(kcal))"
    }
}

// MARK: - Preview snapshot

extension LastRunSnapshot {
    static var preview: LastRunSnapshot {
        let totalMeters: Double = 5240
        // Build a smooth synthetic paceFine + hrFine for previews.
        let bucketCount = Int((totalMeters / 100).rounded(.up))   // 53 buckets
        let paceFine: [Double] = (0..<bucketCount).map { i in
            let t = Double(i) / Double(max(1, bucketCount - 1))
            return 300 + sin(t * .pi * 3) * 18 + t * 12
        }
        let hrFine: [Double] = (0..<bucketCount).map { i in
            let t = Double(i) / Double(max(1, bucketCount - 1))
            return 140 + sin(t * .pi * 2.2) * 14 + t * 22
        }
        return LastRunSnapshot(
            runId: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-1800),
            distanceMeters: totalMeters,
            durationSeconds: 1623,
            avgPaceSecPerKm: 309,
            energyKcal: 312,
            runTypeRaw: "outdoor",
            paceSplits: [298, 305, 312, 308, 314, 320],
            hrSplits: [142, 154, 158, 161, 163, 168],
            paceFine: paceFine,
            hrFine: hrFine
        )
    }
}

#Preview(as: .systemSmall) {
    LastRunWidget()
} timeline: {
    LastRunEntry(date: .now, snapshot: .preview)
    LastRunEntry(date: .now, snapshot: nil)
}

#Preview(as: .systemMedium) {
    LastRunWidget()
} timeline: {
    LastRunEntry(date: .now, snapshot: .preview)
    LastRunEntry(date: .now, snapshot: nil)
}
