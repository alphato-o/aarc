import SwiftUI
import SwiftData
import AARCKit

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    // Active runs only — tombstoned (soft-deleted) runs live in
    // "Recently Deleted" and are excluded here.
    @Query(filter: #Predicate<RunRecord> { $0.deletedAt == nil },
           sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]
    // Counts for the toolbar menu.
    @Query(filter: #Predicate<RunRecord> { $0.deletedAt != nil }) private var deletedRuns: [RunRecord]
    @Query(filter: #Predicate<RunRecord> { $0.deletedAt == nil && $0.isTestData == true })
    private var testRuns: [RunRecord]

    @State private var category: Category = .real
    private enum Category: String, CaseIterable { case real = "Runs", test = "Test" }
    /// Runs shown for the selected category.
    private var shownRuns: [RunRecord] {
        runs.filter { category == .test ? $0.isTestData : !$0.isTestData }
    }

    @State private var pendingDelete: RunRecord?
    /// Detached summary store seeded from a past run, driving the share sheet.
    @State private var shareStore: RunSummaryStore?
    @State private var confirmTestPurge = false
    @State private var deletingId: PersistentIdentifier?
    @State private var deleteError: String?
    @State private var importing = false
    @State private var importResult: String?

    /// Archived diagnostics logs on device, newest first. Loaded off-main.
    @State private var archivedRuns: [RunEventLog.ArchivedRun] = []

    /// A history run matches a diagnostics log when their start times are
    /// within this window (the diagnostics `runId` ≠ `RunRecord.id`).
    private static let matchWindow: TimeInterval = 120

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Category", selection: $category) {
                    ForEach(Category.allCases, id: \.self) { c in
                        Text(categoryLabel(c)).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)

                if shownRuns.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(shownRuns) { run in runRow(run) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink {
                            RecentlyDeletedView()
                        } label: {
                            Label("Recently Deleted\(deletedRuns.isEmpty ? "" : " (\(deletedRuns.count))")",
                                  systemImage: "trash.slash")
                        }
                        if !testRuns.isEmpty {
                            Button(role: .destructive) {
                                confirmTestPurge = true
                            } label: {
                                Label("Delete all test runs (\(testRuns.count))", systemImage: "flask")
                            }
                        }
                        NavigationLink {
                            RunDiagnosticsListView()
                        } label: {
                            Label("Run Diagnostics", systemImage: "waveform.path.ecg")
                        }
                        Divider()
                        Button {
                            Task {
                                importing = true
                                let n = await HealthImporter.importMissing(context: modelContext)
                                importing = false
                                importResult = n == 0
                                    ? "Nothing to import — every Apple Health run is already in AARC."
                                    : "Recovered \(n) run\(n == 1 ? "" : "s") from Apple Health."
                            }
                        } label: {
                            Label(importing ? "Importing…" : "Import from Apple Health",
                                  systemImage: "square.and.arrow.down")
                        }
                        .disabled(importing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task {
                archivedRuns = await Task.detached(priority: .utility) {
                    RunEventLog.archivedRuns()
                }.value
                // Purge tombstones past the retention window (permanently).
                RunTrash.purgeExpired(context: modelContext)
            }
            // Soft-delete confirmation (recoverable).
            .alert("Delete this run?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { run in
                Button("Delete", role: .destructive) { Task { await softDelete(run) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Moves it to Recently Deleted (kept \(RunTrash.retentionDays) days, with its Apple Health workout intact) so you can restore it. It's permanently removed after that.")
            }
            // Batch test-run purge confirmation.
            .alert("Delete all \(testRuns.count) test runs?", isPresented: $confirmTestPurge) {
                Button("Delete", role: .destructive) { Task { await softDeleteTestRuns() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Moves every test run to Recently Deleted. Restorable for \(RunTrash.retentionDays) days.")
            }
            .alert("Couldn't delete", isPresented: Binding(
                get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
            ), presenting: deleteError) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
            .alert("Import from Apple Health", isPresented: Binding(
                get: { importResult != nil }, set: { if !$0 { importResult = nil } }
            ), presenting: importResult) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
            .sheet(isPresented: Binding(
                get: { shareStore != nil }, set: { if !$0 { shareStore = nil } }
            )) {
                if let shareStore {
                    RunShareComposer(target: .wholeRun, store: shareStore)
                }
            }
        }
    }

    /// Re-open a finished run for sharing: build a detached summary store from
    /// it (series from the persisted blob or HealthKit) and present the same
    /// composer used at the end of a run, so a fresh image/video can be made.
    private func presentShare(_ run: RunRecord) {
        let store = RunSummaryStore()
        shareStore = store
        Task { await store.loadFromHistory(run) }
    }

    private func categoryLabel(_ c: Category) -> String {
        guard c == .test else { return "Runs" }
        return testRuns.isEmpty ? "Test" : "Test (\(testRuns.count))"
    }

    @ViewBuilder
    private var emptyState: some View {
        let title: String = category == .test ? "No test runs" : "No runs yet"
        let icon: String = category == .test ? "flask" : "list.bullet.rectangle"
        let detail: String = category == .test
            ? "Runs you do in test / simulate mode land here, kept apart from real runs."
            : "Finish a run on your Apple Watch and it will appear here within a few seconds."
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
    }

    @ViewBuilder
    private func runRow(_ run: RunRecord) -> some View {
        NavigationLink {
            RunDetailView(run: run)
        } label: {
            RunListRow(run: run)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = run } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { presentShare(run) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.orange)
            if let archived = diagnostics(for: run) {
                NavigationLink {
                    ControlRoomView(replay: archived)
                } label: {
                    Label("Control Room", systemImage: "waveform.path.ecg")
                }
                .tint(.purple)
            }
        }
        .contextMenu {
            Button { presentShare(run) } label: {
                Label("Share run", systemImage: "square.and.arrow.up")
            }
            Button {
                run.isTestData.toggle()
                try? modelContext.save()
            } label: {
                Label(run.isTestData ? "Unmark test run" : "Mark as test run",
                      systemImage: run.isTestData ? "flask.fill" : "flask")
            }
            Button(role: .destructive) { pendingDelete = run } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .opacity(deletingId == run.persistentModelID ? 0.4 : 1)
    }

    private func diagnostics(for run: RunRecord) -> RunEventLog.ArchivedRun? {
        archivedRuns
            .filter { abs($0.startedAt.timeIntervalSince(run.startedAt)) <= Self.matchWindow }
            .min { abs($0.startedAt.timeIntervalSince(run.startedAt))
                 < abs($1.startedAt.timeIntervalSince(run.startedAt)) }
    }

    /// SOFT delete: tombstone the row, KEEP the Apple Health workout (so a
    /// restore is lossless). The HK workout is only removed on permanent
    /// delete / sweep.
    private func softDelete(_ run: RunRecord) async {
        deletingId = run.persistentModelID
        defer { deletingId = nil }
        run.deletedAt = .now
        do { try modelContext.save() }
        catch { deleteError = "Couldn't move run to Recently Deleted: \(error.localizedDescription)" }
        // Mirror to the cloud dashboard (soft-delete) if a diagnostics log
        // links this run to a cloud run_id.
        if let arch = diagnostics(for: run) { CloudRunSync.delete(runId: arch.runId) }
    }

    private func softDeleteTestRuns() async {
        let now = Date()
        let toDelete = testRuns
        for run in toDelete { run.deletedAt = now }
        do { try modelContext.save() }
        catch { deleteError = "Couldn't delete test runs: \(error.localizedDescription)" }
        for run in toDelete {
            if let arch = diagnostics(for: run) { CloudRunSync.delete(runId: arch.runId) }
        }
    }
}

// MARK: - Recently Deleted

struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<RunRecord> { $0.deletedAt != nil },
           sort: \RunRecord.deletedAt, order: .reverse) private var deleted: [RunRecord]
    @State private var error: String?
    @State private var archivedRuns: [RunEventLog.ArchivedRun] = []

    private func cloudId(for run: RunRecord) -> UUID? {
        archivedRuns
            .filter { abs($0.startedAt.timeIntervalSince(run.startedAt)) <= 120 }
            .min { abs($0.startedAt.timeIntervalSince(run.startedAt))
                 < abs($1.startedAt.timeIntervalSince(run.startedAt)) }?.runId
    }

    var body: some View {
        Group {
            if deleted.isEmpty {
                ContentUnavailableView("Nothing deleted",
                    systemImage: "trash.slash",
                    description: Text("Deleted runs land here for \(RunTrash.retentionDays) days, then they're gone for good."))
            } else {
                List {
                    Section {
                        ForEach(deleted) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                RunListRow(run: run)
                                if let d = run.deletedAt {
                                    Text("Deleted \(d, format: .relative(presentation: .named)) · purged in \(RunTrash.daysLeft(for: run))d")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { restore(run) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                                    .tint(.green)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { Task { await purge(run) } } label: {
                                    Label("Delete Now", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Text("Swipe right to restore, left to delete permanently (removes the Apple Health workout too).")
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            archivedRuns = await Task.detached(priority: .utility) {
                RunEventLog.archivedRuns()
            }.value
        }
        .alert("Couldn't complete", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        ), presenting: error) { _ in Button("OK", role: .cancel) {} } message: { Text($0) }
    }

    private func restore(_ run: RunRecord) {
        run.deletedAt = nil
        try? modelContext.save()
        if let id = cloudId(for: run) { CloudRunSync.restore(runId: id) }
    }

    private func purge(_ run: RunRecord) async {
        let id = cloudId(for: run)
        if let hk = await RunTrash.permanentlyDelete(run, context: modelContext) {
            error = hk
        }
        if let id { CloudRunSync.purge(runId: id) }
    }
}

// MARK: - Trash helpers

enum RunTrash {
    static let retentionDays = 30

    static func daysLeft(for run: RunRecord) -> Int {
        guard let d = run.deletedAt else { return retentionDays }
        let elapsed = Date().timeIntervalSince(d) / 86_400
        return max(0, retentionDays - Int(elapsed))
    }

    /// Permanently remove a run: delete its Apple Health workout (best
    /// effort) and the SwiftData row. Returns a non-nil HK error string if
    /// the workout couldn't be removed (the row is still deleted).
    @MainActor
    @discardableResult
    static func permanentlyDelete(_ run: RunRecord, context: ModelContext) async -> String? {
        var hkError: String?
        if let uuid = run.healthKitWorkoutUUID {
            do { _ = try await HealthKitReader.shared.deleteWorkout(uuid: uuid) }
            catch { hkError = "Apple Health deletion failed: \(error.localizedDescription)" }
        }
        context.delete(run)
        try? context.save()
        return hkError
    }

    /// Sweep: permanently delete tombstones past the retention window.
    @MainActor
    static func purgeExpired(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let tombstoned = (try? context.fetch(FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.deletedAt != nil }
        ))) ?? []
        let expired = tombstoned.filter { ($0.deletedAt ?? .now) < cutoff }
        guard !expired.isEmpty else { return }
        Task { @MainActor in
            for run in expired { await permanentlyDelete(run, context: context) }
        }
    }
}

// MARK: - Row

private struct RunListRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(run.startedAt, format: .dateTime.weekday().day().month(.abbreviated).hour().minute())
                    .font(.subheadline.bold())
                if run.isTestData {
                    Text("TEST").font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
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
                if run.cachedEnergyKcal > 0 { Text("\(Int(run.cachedEnergyKcal)) kcal") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }
    private func formatDuration(_ s: Double) -> String {
        let total = Int(s); let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    private func formatPace(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        return String(format: "%d:%02d /km", Int(secPerKm) / 60, Int(secPerKm) % 60)
    }
}

#Preview {
    HistoryView().preferredColorScheme(.dark)
}
