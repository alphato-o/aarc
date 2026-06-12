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
    @State private var phoneSession = PhoneSession.shared
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
        // Plan section and start-buttons section share the bulk of the
        // viewport. Both use layoutPriority(2) and grow proportionally;
        // the buttons get a slightly higher growth weight via a larger
        // intrinsic min height so they end up a touch taller than the
        // plan section — matching the runner's mental priority (set
        // distance once, hit Start often).
        VStack(spacing: 14) {
            planSection(planStore: planStore)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            trackingSourcePicker
            testRunToggle
            watchUnreachableBanner
            startButtons
                .frame(maxHeight: .infinity)
                .layoutPriority(1.05)
            statusFooter
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sticky "test run" toggle. When on, the run is tagged as test data
    /// (TEST badge in History, sweepable via "Delete all test runs"). Stays
    /// where the user left it, and shows its state so it's never a surprise.
    @ViewBuilder
    private var testRunToggle: some View {
        VStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { orchestrator.testMode != .off },
                set: { orchestrator.testMode = $0 ? .real : .off }
            )) {
                Label {
                    Text(orchestrator.testMode != .off ? "Test run — not saved to Apple Health" : "Test run")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "flask")
                }
                .foregroundStyle(orchestrator.testMode != .off ? .orange : .secondary)
            }
            .tint(.orange)

            if orchestrator.testMode != .off {
                Picker("", selection: Binding(
                    get: { orchestrator.testMode == .simulate },
                    set: { orchestrator.testMode = $0 ? .simulate : .real }
                )) {
                    Text("I'll actually run").tag(false)
                    Text("Simulate at my desk").tag(true)
                }
                .pickerStyle(.segmented)
                Text(orchestrator.testMode == .simulate
                     ? "No GPS — a synthetic run drives the coaching; steer it from the Control Room."
                     : "Real GPS/pace, but nothing is written to Apple Health.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(orchestrator.testMode != .off ? Color.orange.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let err = orchestrator.lastError {
            errorBox(err)
        } else if orchestrator.phase == .watchTimedOut {
            watchTimeoutCard
        } else if orchestrator.phase == .awaitingWatch {
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

    /// Yellow warning card shown when the tracking source is set to
    /// Watch but the watch app isn't actually reachable. Tappable —
    /// one tap flips the source to Phone only so the runner doesn't
    /// have to fish through Settings while waiting on a treadmill.
    /// Red card shown when a phone-initiated watch start timed out or
    /// was declined. The guarantee surface: every handover attempt ends
    /// here (with one-tap phone-only + retry) or in a tracking run —
    /// never a silent dead end.
    private var watchTimeoutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "applewatch.slash")
                    .foregroundStyle(.red)
                Text("Watch didn't start")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.red)
            }
            Text(orchestrator.watchFailureReason ?? "No response from the watch.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Text("Tip: if you force-quit the watch app recently, watchOS blocks auto-launch — open AARC on the watch once, then Retry. Check both devices show the same build in their footer.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await orchestrator.startOnPhoneInstead() }
                } label: {
                    Text("Start on phone")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    Task { await orchestrator.retryWatchStart() }
                } label: {
                    Text("Retry watch")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    orchestrator.dismissWatchTimeout()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var watchUnreachableBanner: some View {
        // Registry drift (the 2026-06-10 failure): iPhone's pairing
        // registry lost the watch app's install record — every WC channel
        // is dead at the OS level while the watch still shows "iPhone
        // reachable". Distinct banner because the remedy is different.
        if trackingSource == .watch, phoneSession.isPaired,
           phoneSession.activationState == .activated,
           !phoneSession.isWatchAppInstalled {
            Button {
                trackingSourceRaw = TrackingSource.phone.rawValue
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.applewatch")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Watch app not registered")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                        Text("iPhone thinks the watch app isn't installed (dev-install glitch). Reboot the watch or reinstall it — or tap to run phone-only.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if phoneSession.buildMismatch, trackingSource == .watch {
            // Dev-deploy drift tripwire: watch and phone are running
            // different builds — schema changes decode-fail silently in
            // that state, so say it loudly the moment it's detected.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch build ≠ phone build")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Watch is on build \(phoneSession.counterpartBuild ?? "?"), phone on \(AppVersion.build). Handover may fail — redeploy both targets.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
        } else if trackingSource == .watch, !phoneSession.isReachable {
            Button {
                trackingSourceRaw = TrackingSource.phone.rawValue
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "applewatch.slash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phoneSession.isPaired ? "Watch app asleep" : "Watch app not reachable")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.yellow)
                        Text(phoneSession.isPaired
                             ? "That's fine — it auto-launches when you hit Start. Tap here to run phone-only instead."
                             : "No paired watch detected. Tap to switch to Phone only.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
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
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 52, weight: .semibold))
                Text(label)
                    .font(.system(.title2, design: .rounded, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background.gradient, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: background.opacity(0.42), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func startTapped(_ runType: RunType) async {
        // A simulated test never involves the watch — it's a desk run driven
        // by synthetic metrics, so always take the phone-only path (which
        // routes to RunSimulator when testMode == .simulate).
        if orchestrator.testMode == .simulate {
            await orchestrator.startPhoneOnly(runType: runType)
            return
        }
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
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting your watch…")
                    .font(.callout.weight(.semibold))
            }
            Text("Launching AARC on the watch automatically — no need to touch it. You'll feel a soft tick when tracking begins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    RunHomeView()
        .preferredColorScheme(.dark)
}
