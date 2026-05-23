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

    private func medium(_ snap: LastRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(snap, compact: false)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatDistanceHero(snap.distanceMeters))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text("KM")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 10)
            }

            if let pace = snap.paceSplits, pace.count >= 2 {
                splitsChart(pace: pace, hr: snap.hrSplits)
                    .frame(height: 32)
                    .padding(.top, 2)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 18) {
                stat(label: "TIME", value: formatDuration(snap.durationSeconds))
                stat(label: "AVG PACE", value: "\(formatPace(snap.avgPaceSecPerKm))/km")
                stat(label: "KCAL", value: formatKcal(snap.energyKcal))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// Dual-line per-km chart: pace + heart rate plotted against
    /// distance. Both series normalised independently to their own
    /// min/max so they share the same vertical space — the lines
    /// describe relative shape (was km 4 your slowest? did HR peak
    /// at km 3?) rather than absolute units. NRC-style: no axis
    /// labels, no gridlines, just two colored lines + small terminal
    /// dots.
    ///
    /// Pace is INVERTED (fastest km = highest point) so the line
    /// visually agrees with intuition: "going faster = going up."
    private func splitsChart(pace: [Double], hr: [Double]?) -> some View {
        Canvas { ctx, size in
            let width = size.width
            let height = size.height
            // Pace line — sage green (brand accent).
            drawSeries(
                ctx: &ctx,
                size: CGSize(width: width, height: height),
                values: pace,
                normalize: { vs, v in
                    // Higher pace value = slower. Invert so the
                    // fastest km plots at the TOP of the chart.
                    let valid = vs.filter { $0 > 0 }
                    guard let lo = valid.min(), let hi = valid.max(), hi > lo else { return 0.5 }
                    return 1.0 - (v - lo) / (hi - lo)
                },
                color: accent,
                lineWidth: 2.0
            )
            // HR line — pink/red. Only renders when present.
            if let hr, hr.contains(where: { $0 > 0 }) {
                drawSeries(
                    ctx: &ctx,
                    size: CGSize(width: width, height: height),
                    values: hr,
                    normalize: { vs, v in
                        let valid = vs.filter { $0 > 0 }
                        guard let lo = valid.min(), let hi = valid.max(), hi > lo else { return 0.5 }
                        // Higher HR plots at the top.
                        return (v - lo) / (hi - lo)
                    },
                    color: hrColor,
                    lineWidth: 1.6
                )
            }
        }
    }

    /// Plot one series as a polyline + small dots. Skips entries with
    /// value 0 (no data — e.g., a km where HR strap dropped out) so
    /// the line doesn't dive to the floor on those gaps; instead it
    /// renders separate segments.
    private func drawSeries(
        ctx: inout GraphicsContext,
        size: CGSize,
        values: [Double],
        normalize: ([Double], Double) -> Double,
        color: Color,
        lineWidth: CGFloat
    ) {
        guard values.count >= 2 else { return }
        let stride = values.count > 1 ? size.width / CGFloat(values.count - 1) : size.width
        // Build a path piece-wise, breaking at gaps.
        var path = Path()
        var penDown = false
        for (i, v) in values.enumerated() {
            guard v > 0 else { penDown = false; continue }
            let x = CGFloat(i) * stride
            let yUnit = normalize(values, v)
            let y = size.height * (1 - CGFloat(yUnit))
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
        ctx.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: lineWidth + 1.5, lineCap: .round))
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

    private func formatKcal(_ kcal: Double) -> String {
        guard kcal.isFinite else { return "—" }
        return "\(Int(kcal))"
    }
}

// MARK: - Preview snapshot

extension LastRunSnapshot {
    static var preview: LastRunSnapshot {
        LastRunSnapshot(
            runId: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-1800),
            distanceMeters: 5240,
            durationSeconds: 1623,
            avgPaceSecPerKm: 309,
            energyKcal: 312,
            runTypeRaw: "outdoor",
            paceSplits: [298, 305, 312, 308, 314, 320],
            hrSplits: [142, 154, 158, 161, 163, 168]
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
