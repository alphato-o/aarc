import SwiftUI
import SwiftData

/// "Test Data" section embedded in `SettingsView`. Owns the wipe flow and
/// the flip-off confirmation. See D19.
struct TestDataSettingsSection: View {
    @Environment(\.modelContext) private var modelContext

    @State private var settings = TestDataSettings.shared

    @State private var workoutCount: Int = 0
    @State private var isWiping = false
    @State private var showWipeAlert = false
    @State private var showFlipOffAlert = false
    @State private var wipeError: String?
    @State private var lastDeletedCount: Int?

    var body: some View {
        @Bindable var settings = settings

        Section {
            Toggle("Tag new runs as test data", isOn: $settings.isTestDataMode)
                .onChange(of: settings.isTestDataMode) { oldValue, newValue in
                    if oldValue == true && newValue == false {
                        showFlipOffAlert = true
                    }
                }

            Toggle("Skip HealthKit writes entirely", isOn: $settings.skipHealthKitWrite)

            LabeledContent("Tagged workouts in Health") {
                if isWiping {
                    ProgressView()
                } else {
                    Text("\(workoutCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let lastWipe = settings.lastWipeDate {
                LabeledContent("Last wipe") {
                    Text(lastWipe, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                showWipeAlert = true
            } label: {
                Label("Wipe AARC test data", systemImage: "trash")
            }
            .disabled(workoutCount == 0 || isWiping)

            if let lastDeletedCount {
                Text("Removed \(lastDeletedCount) workout\(lastDeletedCount == 1 ? "" : "s") from Apple Health.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Test Data")
        } footer: {
            Text("AARC stamps every workout it writes with `aarc.test_data: true`. Wipe removes only those workouts and their associated samples and route. Real workouts in Apple Health are never touched.")
        }
        .alert(
            "Wipe \(workoutCount) workout\(workoutCount == 1 ? "" : "s") from Apple Health?",
            isPresented: $showWipeAlert
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Wipe", role: .destructive) {
                Task { await performWipe() }
            }
        } message: {
            Text("This permanently deletes AARC-tagged workouts from Apple Health on this device (and via iCloud Sync if enabled). Other workouts are not affected.")
        }
        .alert(
            "Future runs will be permanent in Health",
            isPresented: $showFlipOffAlert
        ) {
            Button("Cancel", role: .cancel) {
                settings.isTestDataMode = true
            }
            Button("Continue") {}
        } message: {
            Text("New runs you record after turning this off will be written to Apple Health without the test marker. They cannot be cleaned up by the Wipe button later.")
        }
        .alert(
            "Wipe failed",
            isPresented: Binding(
                get: { wipeError != nil },
                set: { if !$0 { wipeError = nil } }
            )
        ) {
            Button("OK") { wipeError = nil }
        } message: {
            Text(wipeError ?? "")
        }
        .task { await refreshCount() }
    }

    private func performWipe() async {
        isWiping = true
        defer { isWiping = false }
        do {
            let uuids = try await TestDataManager.shared.wipe()
            try cleanupLocalRecords(matching: Set(uuids))
            settings.lastWipeDate = .now
            lastDeletedCount = uuids.count
            await refreshCount()
        } catch {
            wipeError = error.localizedDescription
        }
    }

    private func cleanupLocalRecords(matching uuids: Set<UUID>) throws {
        guard !uuids.isEmpty else { return }
        let descriptor = FetchDescriptor<RunRecord>()
        let records = try modelContext.fetch(descriptor)
        for record in records {
            if let hkUUID = record.healthKitWorkoutUUID, uuids.contains(hkUUID) {
                modelContext.delete(record)
            }
        }
        try modelContext.save()
    }

    private func refreshCount() async {
        workoutCount = await TestDataManager.shared.testWorkoutCount()
    }
}
