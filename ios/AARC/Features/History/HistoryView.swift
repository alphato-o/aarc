import SwiftUI
import SwiftData
import AARCKit

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]

    @State private var pendingDelete: RunRecord?
    @State private var deletingId: PersistentIdentifier?
    @State private var deleteError: String?

    /// Archived diagnostics logs on device, newest first. Loaded off-main.
    /// Used to surface a per-row "Control Room" replay affordance when a
    /// history run lines up with a recorded diagnostics log.
    @State private var archivedRuns: [RunEventLog.ArchivedRun] = []

    /// A history run matches a diagnostics log when their start times are
    /// within this window. The diagnostics `runId` is the mirroring/run id,
    /// which need not equal `RunRecord.id`, so we can't match by id.
    private static let matchWindow: TimeInterval = 120

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
                    List {
                        ForEach(runs) { run in
                            NavigationLink {
                                RunDetailView(run: run)
                            } label: {
                                RunListRow(run: run)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = run
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if let archived = diagnostics(for: run) {
                                    NavigationLink {
                                        ControlRoomView(replay: archived)
                                    } label: {
                                        Label("Control Room", systemImage: "waveform.path.ecg")
                                    }
                                    .tint(.purple)
                                }
                            }
                            .opacity(deletingId == run.persistentModelID ? 0.4 : 1)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RunDiagnosticsListView()
                    } label: {
                        Label("Run Diagnostics", systemImage: "waveform.path.ecg")
                    }
                }
            }
            .task {
                let archived = await Task.detached(priority: .utility) {
                    RunEventLog.archivedRuns()
                }.value
                archivedRuns = archived
            }
            .alert(
                "Delete this run from AARC and Apple Health?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { run in
                Button("Delete", role: .destructive) {
                    Task { await delete(run) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { run in
                Text("Removes the AARC row AND the underlying workout in Apple Fitness / Health (HR, distance, route). This can't be undone.")
            }
            .alert(
                "Couldn't fully delete",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                ),
                presenting: deleteError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text(detail)
            }
        }
    }

    /// The archived diagnostics log for a history run, if one exists, matched
    /// by start time within `matchWindow` (their ids differ). Picks the
    /// closest-in-time log when several fall inside the window.
    private func diagnostics(for run: RunRecord) -> RunEventLog.ArchivedRun? {
        archivedRuns
            .filter { abs($0.startedAt.timeIntervalSince(run.startedAt)) <= Self.matchWindow }
            .min { a, b in
                abs(a.startedAt.timeIntervalSince(run.startedAt))
                    < abs(b.startedAt.timeIntervalSince(run.startedAt))
            }
    }

    private func delete(_ run: RunRecord) async {
        deletingId = run.persistentModelID
        defer { deletingId = nil }

        var hkFailure: String?
        if let uuid = run.healthKitWorkoutUUID {
            do {
                _ = try await HealthKitReader.shared.deleteWorkout(uuid: uuid)
                // (returns false if HK already lost it — that's fine,
                // user might have deleted it from Apple Fitness first.)
            } catch {
                hkFailure = error.localizedDescription
            }
        }

        modelContext.delete(run)
        do {
            try modelContext.save()
        } catch {
            deleteError = "AARC row delete failed: \(error.localizedDescription)"
            return
        }

        if let hkFailure {
            deleteError = "AARC row removed, but Apple Health deletion failed: \(hkFailure). Open Apple Fitness or Health to remove it manually."
        }
    }
}

private struct RunListRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.startedAt, format: .dateTime.weekday().day().month(.abbreviated).hour().minute())
                .font(.subheadline.bold())

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
