import SwiftUI
import AARCKit

struct RunHomeView: View {
    @State private var selectedPersonality: Personality = .roastCoach
    @State private var orchestrator = RunOrchestrator.shared
    @State private var planStore = ScriptPreviewStore.shared

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

    /// Card shown after a phone-initiated Start has been dispatched.
    /// Spells out the watch-launch handoff so the user understands they
    /// just need to tap the notification on their wrist.
    private var sentToWatchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .imageScale(.medium)
                    .foregroundStyle(.green)
                Text("Sent to your watch")
                    .font(.callout.weight(.semibold))
            }
            Text("Your watch will buzz. Tap the AARC notification on your wrist to start the workout. (iOS won't let apps force-open a watch app — the notification is the handoff.)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await PhoneNotificationCenter.shared.scheduleStartCue() }
            } label: {
                Label("Re-tap my wrist", systemImage: "bell.badge")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var startSection: some View {
        let phase = orchestrator.phase
        let isBusy = phase == .generating

        VStack(spacing: 10) {
            if isBusy {
                ProgressView()
                Text("Coach loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Generating script + warming the first lines")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
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
                        Task { await orchestrator.startFromPhone(runType: .treadmill, personalityId: selectedPersonality.id) }
                    } label: {
                        Label("Treadmill", systemImage: "figure.run.treadmill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        Task { await orchestrator.startFromPhone(runType: .outdoor, personalityId: selectedPersonality.id) }
                    } label: {
                        Label("Outdoor", systemImage: "figure.run")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }

                if phase == .sentToWatch {
                    sentToWatchCard
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

    private func formatKm(_ km: Double) -> String {
        km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }
}

#Preview {
    RunHomeView()
        .preferredColorScheme(.dark)
}
