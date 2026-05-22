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

            if let splits = snap.paceSplits, splits.count >= 2 {
                paceSparkline(splits: splits)
                    .frame(height: 20)
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

    /// Slim per-km bar sparkline — each bar's height tracks how that
    /// kilometre's pace compares to the slowest km of the run (fastest
    /// km = tallest bar). Reads as "kept it together or fell off near
    /// the end?" without needing axis labels.
    private func paceSparkline(splits: [Double]) -> some View {
        let valid = splits.filter { $0 > 0 }
        let maxPace = valid.max() ?? 1
        let minPace = valid.min() ?? 0
        let span = max(1, maxPace - minPace)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(splits.enumerated()), id: \.offset) { _, pace in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.45)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(
                        y: CGFloat(1 - ((pace - minPace) / span)) * 0.7 + 0.3,
                        anchor: .bottom
                    )
            }
        }
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
        // Vivid amber-orange that pops on the all-black canvas — close
        // to NRC's signature volt-orange without being a copy.
        Color(red: 1.0, green: 0.55, blue: 0.20)
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
            paceSplits: [298, 305, 312, 308, 314, 320]
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
