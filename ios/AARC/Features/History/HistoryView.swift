import SwiftUI
import SwiftData
import AARCKit

struct HistoryView: View {
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Finish a run on your Apple Watch and it will appear here within a few seconds.")
                    )
                } else {
                    List(runs) { run in
                        NavigationLink {
                            RunDetailView(run: run)
                        } label: {
                            RunListRow(run: run)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
        }
    }
}

private struct RunListRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.startedAt, format: .dateTime.weekday().day().month(.abbreviated).hour().minute())
                    .font(.subheadline.bold())
                Spacer()
                if run.isTestData { TestBadge() }
            }

            HStack(spacing: 12) {
                Label(formatDistance(run.cachedDistanceMeters), systemImage: "ruler")
                Label(formatDuration(run.cachedDurationSeconds), systemImage: "stopwatch")
                Label(formatPace(run.cachedAvgPaceSecPerKm), systemImage: "speedometer")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Image(systemName: run.runTypeRaw == "treadmill" ? "figure.run.treadmill" : "figure.run")
                Text(run.runTypeRaw.capitalized)
                Spacer()
                if run.cachedEnergyKcal > 0 {
                    Text("\(Int(run.cachedEnergyKcal)) kcal")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatPace(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm) / 60
        let r = Int(secPerKm) % 60
        return String(format: "%d:%02d /km", m, r)
    }
}

#Preview {
    HistoryView()
        .preferredColorScheme(.dark)
}
