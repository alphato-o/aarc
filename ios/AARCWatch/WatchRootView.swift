import SwiftUI
import AARCKit

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session
    @Environment(WorkoutSessionHost.self) private var host

    @State private var hkAuthorized = HealthKitClient.shared.canHostWorkouts
    @State private var requestingAuth = false
    @State private var startError: String?
    @State private var mode: RunType = .treadmill

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)

                    Text("AARC")
                        .font(.title3.bold())

                    Text(AppVersion.versionString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    contentForCurrentPhase

                    if host.phase == .idle {
                        Divider()
                        Group {
                            LabeledContent("Phone reachable", value: session.isReachable ? "Yes" : "No")
                            if let last = session.lastInboundText {
                                Text("Last: \(last)")
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { isInActiveSessionPhase },
                    set: { if !$0 { /* user can't manually pop */ } }
                )
            ) {
                WatchActiveRunView()
            }
        }
    }

    /// True once the run is actually happening or has just ended — drive
    /// the navigation push to the active run view from here.
    private var isInActiveSessionPhase: Bool {
        switch host.phase {
        case .running, .paused, .ended: return true
        case .idle, .preparing, .countingDown, .error: return false
        }
    }

    @ViewBuilder
    private var contentForCurrentPhase: some View {
        switch host.phase {
        case .idle:
            idleContent
        case .preparing:
            preparingContent
        case .countingDown:
            countdownContent
        case .running, .paused, .ended:
            // Navigation pushes WatchActiveRunView — keep this branch
            // empty so we don't double-render.
            EmptyView()
        case .error:
            errorContent
        }
    }

    // MARK: - Idle (start buttons)

    @ViewBuilder
    private var idleContent: some View {
        if !hkAuthorized {
            Button {
                Task { await requestHK() }
            } label: {
                if requestingAuth {
                    ProgressView()
                } else {
                    Text("Allow Health")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            VStack(spacing: 6) {
                Button {
                    Task {
                        await host.beginRun(
                            runType: .treadmill,
                            personalityId: "roast_coach",
                            prepareScriptOnPhone: true
                        )
                    }
                } label: {
                    Label("Treadmill", systemImage: "figure.run.treadmill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

                Button {
                    Task {
                        await host.beginRun(
                            runType: .outdoor,
                            personalityId: "roast_coach",
                            prepareScriptOnPhone: true
                        )
                    }
                } label: {
                    Label("Outdoor", systemImage: "figure.run")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        if let startError {
            Text(startError)
                .font(.caption2)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Preparing (waiting for phone)

    @ViewBuilder
    private var preparingContent: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
            Text("Coach loading…")
                .font(.callout.bold())
            Text("Generating roast")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                host.cancelPreparation()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Countdown (3-2-1)

    @ViewBuilder
    private var countdownContent: some View {
        VStack(spacing: 4) {
            Text(host.countdownRemaining > 0 ? "\(host.countdownRemaining)" : "GO")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.green)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("Get ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Error

    @ViewBuilder
    private var errorContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(host.lastError ?? "Something went wrong")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Try again") {
                host.cancelPreparation()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
    }

    // MARK: - HK auth

    private func requestHK() async {
        requestingAuth = true
        defer { requestingAuth = false }
        do {
            try await HealthKitClient.shared.requestAuthorization()
            hkAuthorized = HealthKitClient.shared.canHostWorkouts
        } catch {
            startError = "Health access denied"
        }
    }
}

#Preview {
    WatchRootView()
        .environment(WatchSession.shared)
        .environment(WorkoutSessionHost.shared)
}
