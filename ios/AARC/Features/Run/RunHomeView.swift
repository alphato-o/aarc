import SwiftUI
import AARCKit

struct RunHomeView: View {
    enum TrackingSource: String, CaseIterable, Identifiable {
        case watch, phone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .watch: return "Watch"
            case .phone: return "Phone only"
            }
        }
    }

    @State private var selectedPersonality: Personality = .roastCoach
    @State private var orchestrator = RunOrchestrator.shared
    @State private var planStore = ScriptPreviewStore.shared
    @AppStorage("aarc.trackingSource") private var trackingSourceRaw: String = TrackingSource.watch.rawValue

    private var trackingSource: TrackingSource {
        TrackingSource(rawValue: trackingSourceRaw) ?? .watch
    }

    var body: some View {
        @Bindable var planStore = planStore

        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 20) {
                        LiveRunTile()

                        if !LiveMetricsConsumer.shared.isRunActive {
                            Image(systemName: "figure.run.circle.fill")
                                .font(.system(size: 88))
                                .foregroundStyle(Theme.accent)

                            planSection(planStore: planStore)
                            companionSection
                            startSection
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("AARC")
            .onAppear { schedulePreGen() }
            .onChange(of: planStore.planKind) { _, _ in schedulePreGen() }
            .onChange(of: planStore.distanceKm) { _, _ in schedulePreGen() }
            .onChange(of: planStore.timeMinutes) { _, _ in schedulePreGen() }
            .onChange(of: selectedPersonality) { _, _ in schedulePreGen() }
        }
    }

    /// Fire-and-forget speculative generation so the script is ready
    /// (or close to ready) before the user taps Start.
    private func schedulePreGen() {
        orchestrator.schedulePreGenerate(personalityId: selectedPersonality.id)
    }

    // MARK: - Plan picker

    @ViewBuilder
    private func planSection(planStore: ScriptPreviewStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Plan", selection: Binding(
                get: { planStore.planKind },
                set: { planStore.planKind = $0 }
            )) {
                Text("Distance").tag(RunPlan.Kind.distance)
                Text("Time").tag(RunPlan.Kind.time)
                Text("Open").tag(RunPlan.Kind.open)
            }
            .pickerStyle(.segmented)

            switch planStore.planKind {
            case .distance:
                Stepper(value: Binding(get: { planStore.distanceKm }, set: { planStore.distanceKm = $0 }),
                        in: 0.5...42, step: 0.5) {
                    HStack {
                        Image(systemName: "ruler")
                        Text("Distance")
                        Spacer()
                        Text("\(formatKm(planStore.distanceKm)) km")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            case .time:
                Stepper(value: Binding(get: { planStore.timeMinutes }, set: { planStore.timeMinutes = $0 }),
                        in: 5...720, step: 5) {
                    HStack {
                        Image(systemName: "stopwatch")
                        Text("Duration")
                        Spacer()
                        Text("\(Int(planStore.timeMinutes)) min")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            case .open:
                Label("No target — run until you stop", systemImage: "infinity")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Companion

    private var companionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Companion")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Personality", selection: $selectedPersonality) {
                ForEach(Personality.allDefaults) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            Text(selectedPersonality.tagline)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Start

    @ViewBuilder
    private var startSection: some View {
        let phase = orchestrator.phase
        let isBusy = phase == .generating

        VStack(spacing: 12) {
            if isBusy {
                ProgressView()
                Text("Coach loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Generating script + warming the first lines")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                trackingSourcePicker
                HStack(spacing: 6) {
                    Text("Start a run")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if orchestrator.isPreGenerating {
                        Image(systemName: "sparkles")
                            .imageScale(.small)
                            .foregroundStyle(.tint)
                            .symbolEffect(.pulse)
                        Text("coach pre-loading")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await startTapped(.treadmill) }
                    } label: {
                        Label("Treadmill", systemImage: "figure.run.treadmill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(trackingSource == .phone) // CMPedometer support TBD

                    Button {
                        Task { await startTapped(.outdoor) }
                    } label: {
                        Label("Outdoor", systemImage: "figure.run")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }

                if trackingSource == .phone {
                    Text("Phone is the tracker. GPS distance + pace + route saved to Apple Health. No watch required.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if phase == .sentToWatch {
                    SentToWatchCard()
                }
            }

            if let err = orchestrator.lastError {
                VStack(spacing: 6) {
                    Text("Couldn't start: \(err)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Dismiss") { orchestrator.clearError() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var trackingSourcePicker: some View {
        VStack(spacing: 4) {
            Picker("Tracking source", selection: $trackingSourceRaw) {
                ForEach(TrackingSource.allCases) { src in
                    Text(src.label).tag(src.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func startTapped(_ runType: RunType) async {
        switch trackingSource {
        case .watch:
            await orchestrator.startFromPhone(runType: runType, personalityId: selectedPersonality.id)
        case .phone:
            await orchestrator.startPhoneOnly(runType: runType, personalityId: selectedPersonality.id)
        }
    }

    private func formatKm(_ km: Double) -> String {
        km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }
}

/// Compact "you're using watch mode, here's what to do" card.
/// No more lock-phone gymnastics — if you don't want to deal with the
/// watch handoff, switch the tracking source to "Phone only" above.
private struct SentToWatchCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .imageScale(.medium)
                    .foregroundStyle(.green)
                Text("Sent to your watch")
                    .font(.callout.weight(.semibold))
            }
            Text("Open AARC on your Apple Watch to begin. iOS does not let apps force-open watch apps — if that's friction, switch the tracking source above to **Phone only**.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    RunHomeView()
        .preferredColorScheme(.dark)
}
