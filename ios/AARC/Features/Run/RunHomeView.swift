import SwiftUI
import AARCKit

/// Home screen for the Run tab. No scroll, exactly one viewport. The
/// two giant Start buttons own the bottom half so a sweaty thumb on a
/// treadmill console can hit them without looking. Companion section
/// is gone — only Roast Coach exists for now, and dropping the picker
/// reclaims the real estate.
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

    @State private var orchestrator = RunOrchestrator.shared
    @State private var planStore = ScriptPreviewStore.shared
    @State private var liveConsumer = LiveMetricsConsumer.shared
    @AppStorage("aarc.trackingSource") private var trackingSourceRaw: String = TrackingSource.watch.rawValue

    private var trackingSource: TrackingSource {
        TrackingSource(rawValue: trackingSourceRaw) ?? .watch
    }

    var body: some View {
        @Bindable var planStore = planStore

        NavigationStack {
            content(planStore: planStore)
                .navigationTitle("AARC")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { schedulePreGen() }
                .onChange(of: planStore.planKind) { _, _ in schedulePreGen() }
                .onChange(of: planStore.distanceKm) { _, _ in schedulePreGen() }
                .onChange(of: planStore.timeMinutes) { _, _ in schedulePreGen() }
                .fullScreenCover(isPresented: Binding(
                    get: { liveConsumer.isRunActive },
                    set: { _ in }
                )) {
                    ActiveRunView()
                        .environment(liveConsumer)
                }
        }
    }

    // MARK: - Content (no scroll, fits one viewport)

    @ViewBuilder
    private func content(planStore: ScriptPreviewStore) -> some View {
        VStack(spacing: 12) {
            planSection(planStore: planStore)
            trackingSourcePicker
            Spacer(minLength: 0)
            startButtons
            if let err = orchestrator.lastError {
                errorBox(err)
            } else if orchestrator.phase == .sentToWatch {
                SentToWatchCard()
            } else if trackingSource == .phone {
                Text("Phone is the tracker. GPS, pace, and route via the iPhone — no watch needed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fire-and-forget speculative generation so the script is ready
    /// (or close to ready) before the user taps Start.
    private func schedulePreGen() {
        orchestrator.schedulePreGenerate()
    }

    // MARK: - Plan picker

    @ViewBuilder
    private func planSection(planStore: ScriptPreviewStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var trackingSourcePicker: some View {
        Picker("Tracking source", selection: $trackingSourceRaw) {
            ForEach(TrackingSource.allCases) { src in
                Text(src.label).tag(src.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Start buttons (oversized — they own the bottom half)

    @ViewBuilder
    private var startButtons: some View {
        let isBusy = orchestrator.phase == .generating

        if isBusy {
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.6)
                Text("Generating opener…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Full script populates in the background once you're moving.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 12) {
                bigStartButton(
                    label: "Treadmill",
                    icon: "figure.run.treadmill",
                    background: Color.green
                ) {
                    Task { await startTapped(.treadmill) }
                }
                .disabled(trackingSource == .phone)
                .opacity(trackingSource == .phone ? 0.4 : 1)

                bigStartButton(
                    label: "Outdoor",
                    icon: "figure.run",
                    background: Color.accentColor
                ) {
                    Task { await startTapped(.outdoor) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigStartButton(
        label: String,
        icon: String,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .semibold))
                Text(label)
                    .font(.system(.title2, design: .rounded, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background.gradient, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: background.opacity(0.45), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func startTapped(_ runType: RunType) async {
        switch trackingSource {
        case .watch:
            await orchestrator.startFromPhone(runType: runType)
        case .phone:
            await orchestrator.startPhoneOnly(runType: runType)
        }
    }

    // MARK: - Error

    private func errorBox(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't start: \(message)")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("Dismiss") { orchestrator.clearError() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatKm(_ km: Double) -> String {
        km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }
}

/// Compact "you're using watch mode" status card.
private struct SentToWatchCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .imageScale(.medium)
                    .foregroundStyle(.green)
                Text("Sent to your watch")
                    .font(.callout.weight(.semibold))
            }
            Text("Open AARC on your watch to start the workout. Or switch to **Phone only** above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    RunHomeView()
        .preferredColorScheme(.dark)
}
