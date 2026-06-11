import SwiftUI
import AARCKit

/// A dedicated list of past runs that have an on-device diagnostics log.
/// Each row pushes the SAME Control Room, in REPLAY mode, reconstructed
/// from that run's recorded events.
///
/// This is the reliable entry point: the History `RunRecord.id` does not
/// always equal the diagnostics `runId` (the diagnostics log is keyed by
/// the HealthKit/mirroring run id), so matching by id can miss. Listing the
/// archived runs directly — by date, duration, and event count — guarantees
/// the founder can always reach a replay when the data exists on device.
struct RunDiagnosticsListView: View {
    @State private var runs: [RunEventLog.ArchivedRun] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                loadingState
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "No diagnostics yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Each run records an on-device event log. Finish a run and its Control Room replay will appear here.")
                )
            } else {
                List {
                    Section {
                        ForEach(runs) { run in
                            NavigationLink {
                                ControlRoomView(replay: run)
                            } label: {
                                DiagnosticsRow(run: run)
                            }
                        }
                    } footer: {
                        Text("Replays are reconstructed from on-device logs (kept ~35 days). Open one to re-watch the full network inspector, run progress, and event stream.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Run Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning on-device logs…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let archived = await Task.detached(priority: .userInitiated) {
            RunEventLog.archivedRuns()
        }.value
        runs = archived
        loaded = true
    }
}

private struct DiagnosticsRow: View {
    let run: RunEventLog.ArchivedRun

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.startedAt, format: .dateTime.weekday().day().month(.abbreviated).hour().minute())
                    .font(.subheadline.bold())
                HStack(spacing: 12) {
                    Label(durationLabel, systemImage: "stopwatch")
                    Label("\(run.eventCount) events", systemImage: "list.bullet")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var durationLabel: String {
        guard let d = run.duration else { return "—" }
        let total = Int(d)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

#Preview {
    NavigationStack {
        RunDiagnosticsListView()
    }
    .preferredColorScheme(.dark)
}
