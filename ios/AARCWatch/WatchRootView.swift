import SwiftUI
import AARCKit

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session
    @Environment(WorkoutSessionHost.self) private var host
    @Environment(\.scenePhase) private var scenePhase

    @State private var hkAuthorized = HealthKitClient.shared.canHostWorkouts
    @State private var requestingAuth = false
    @State private var startError: String?
    @State private var mode: RunType = .treadmill
    @State private var breadcrumbs = WatchBreadcrumbs.shared
    @State private var showBreadcrumbs = false

    var body: some View {
        // State-driven root, NOT push navigation. A phone-initiated run
        // starts while this app is background-launched (wrist down) —
        // programmatic navigationDestination pushes performed while the
        // scene is inactive are the classic watchOS source of blank /
        // stranded UI (the build-71 "wonky until force-quit" bug). With
        // a root switch, whatever phase we're in when the user raises
        // their wrist is simply the first frame rendered — there is no
        // transition to lose. (Apple's multi-device workout sample uses
        // exactly this pattern.)
        Group {
            if isInActiveSessionPhase {
                WatchActiveRunView()
            } else {
                idleRoot
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Breadcrumb every scene transition: tells us whether watchOS
            // ever actually foregrounded the app after a remote start
            // (the "app never materialized on screen" investigation).
            WatchBreadcrumbs.shared.drop("scene \(String(describing: newPhase)) (phase \(host.phase.rawValue))")
            if newPhase == .active {
                // Refresh stale auth state + sweep for a pending start
                // command that may have landed while no delegate fired.
                hkAuthorized = HealthKitClient.shared.canHostWorkouts
                WatchSession.shared.reconsumePendingContext()
            }
        }
    }

    private var idleRoot: some View {
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
                            if session.buildMismatch {
                                Text("⚠︎ Phone build \(session.counterpartBuild ?? "?") ≠ watch \(AppVersion.build) — redeploy both")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.center)
                            }
                            if let last = session.lastInboundText {
                                Text("Last: \(last)")
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .font(.footnote)

                        // On-wrist flight recorder: the persisted launch/
                        // start breadcrumb trail. After a failed phone→
                        // watch handover, this answers "did the app even
                        // launch? did handle() fire? did start() throw?"
                        // without a Mac.
                        Button(showBreadcrumbs ? "Hide launch log" : "Launch log") {
                            showBreadcrumbs.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        if showBreadcrumbs {
                            VStack(alignment: .leading, spacing: 2) {
                                if breadcrumbs.entries.isEmpty {
                                    Text("no events yet")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                ForEach(Array(breadcrumbs.recentFirst.prefix(15).enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button("Clear") { breadcrumbs.clear() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    /// True while the run is actually happening — drives the root switch
    /// to the active run view. `.ended` is no longer in this set: the
    /// host returns the phase to `.idle` at end-of-run, so the root
    /// swaps back automatically (the old push binding kept `.ended` true
    /// forever with no way out — the stranded-UI bug).
    private var isInActiveSessionPhase: Bool {
        switch host.phase {
        case .running, .paused: return true
        case .idle, .preparing, .countingDown, .error, .ended: return false
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
            Button("Cancel") {
                host.cancelPreparation()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
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
            // Local-first escape: the watch can ALWAYS track a run on
            // its own — the coach attaches later if the phone recovers.
            Button("Start without coach") {
                host.startWithoutCoach()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)
            Button("Back") {
                host.cancelPreparation()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
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
