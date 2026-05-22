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
        VStack(spacing: 14) {
            // The plan section is the visual anchor of the screen —
            // takes the upper half. Layout-priority pushes start buttons
            // down so they sit in roughly the lower third.
            planSection(planStore: planStore)
                .layoutPriority(2)
            trackingSourcePicker
            startButtons
            statusFooter
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusFooter: some View {
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

    /// Fire-and-forget speculative generation so the script is ready
    /// (or close to ready) before the user taps Start.
    private func schedulePreGen() {
        orchestrator.schedulePreGenerate()
    }

    // MARK: - Plan picker

    @ViewBuilder
    private func planSection(planStore: ScriptPreviewStore) -> some View {
        VStack(spacing: 18) {
            // Larger segmented control — taller cells, bigger label.
            Picker("Plan", selection: Binding(
                get: { planStore.planKind },
                set: { planStore.planKind = $0 }
            )) {
                Text("Distance").tag(RunPlan.Kind.distance)
                Text("Time").tag(RunPlan.Kind.time)
                Text("Open").tag(RunPlan.Kind.open)
            }
            .pickerStyle(.segmented)
            .font(.title3.weight(.semibold))
            .frame(minHeight: 50)

            // Big value display — center stage. Plus/minus buttons on
            // either side. Lets the runner pick distance or time at a
            // glance from across the treadmill console.
            switch planStore.planKind {
            case .distance:
                bigValueStepper(
                    icon: "ruler",
                    value: formatKm(planStore.distanceKm),
                    unit: "km",
                    canDecrement: planStore.distanceKm > 0.5,
                    canIncrement: planStore.distanceKm < 42,
                    onDecrement: {
                        planStore.distanceKm = max(0.5, planStore.distanceKm - 0.5)
                    },
                    onIncrement: {
                        planStore.distanceKm = min(42, planStore.distanceKm + 0.5)
                    }
                )
            case .time:
                bigValueStepper(
                    icon: "stopwatch",
                    value: "\(Int(planStore.timeMinutes))",
                    unit: "min",
                    canDecrement: planStore.timeMinutes > 5,
                    canIncrement: planStore.timeMinutes < 720,
                    onDecrement: {
                        planStore.timeMinutes = max(5, planStore.timeMinutes - 5)
                    },
                    onIncrement: {
                        planStore.timeMinutes = min(720, planStore.timeMinutes + 5)
                    }
                )
            case .open:
                VStack(spacing: 8) {
                    Image(systemName: "infinity")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("Run until you stop")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Centered "[-]    big number unit    [+]" picker. Used for both
    /// distance and time plans so the visual weight matches whichever
    /// the runner is configuring.
    @ViewBuilder
    private func bigValueStepper(
        icon: String,
        value: String,
        unit: String,
        canDecrement: Bool,
        canIncrement: Bool,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            stepperButton(systemImage: "minus", enabled: canDecrement, action: onDecrement)

            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(unit)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            stepperButton(systemImage: "plus", enabled: canIncrement, action: onIncrement)
        }
    }

    private func stepperButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(enabled ? Theme.accent : Color.gray.opacity(0.3))
                )
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
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
            .frame(maxWidth: .infinity)
        }
    }

    private func bigStartButton(
        label: String,
        icon: String,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .semibold))
                Text(label)
                    .font(.system(.title3, design: .rounded, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(background.gradient, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: background.opacity(0.40), radius: 10, y: 3)
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
