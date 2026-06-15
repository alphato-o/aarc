import SwiftUI
import AARCKit

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session
    @Environment(WorkoutSessionHost.self) private var host
    @Environment(\.scenePhase) private var scenePhase

    /// Env-gated screenshot hook (never set in production) so the authorized
    /// launch state can be verified on the simulator without HK auth.
    private static let previewAuth = ProcessInfo.processInfo.environment["AARC_PREVIEW_AUTH"] == "1"
    @State private var hkAuthorized = previewAuth || HealthKitClient.shared.canHostWorkouts
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
            if let preview = ProcessInfo.processInfo.environment["AARC_PREVIEW"], !preview.isEmpty {
                WatchPreviewGallery(screen: preview)
            } else if isInActiveSessionPhase {
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
                hkAuthorized = Self.previewAuth || HealthKitClient.shared.canHostWorkouts
                WatchSession.shared.reconsumePendingContext()
                // Self-heal: if the UI thinks we're idle but HealthKit
                // has a live workout session for this app (prior process
                // died after starting it), reattach so the run UI and
                // End controls come back. No-op when nothing to recover.
                if host.phase == .idle || host.phase == .error || host.phase == .ended {
                    host.recoverActiveSession()
                }
            }
        }
    }

    private var idleRoot: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // ABOVE THE FOLD: brand header + start buttons ONLY. This
                    // block fills the full visible height, so the diagnostics
                    // below never peek into the first frame — a clean launch.
                    VStack(spacing: 10) {
                        header
                        contentForCurrentPhase
                        Spacer(minLength: 0)
                    }
                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in length + 36 }
                    .padding(.horizontal)

                    // BELOW THE FOLD: diagnostics, revealed only on a scroll.
                    if host.phase == .idle {
                        diagnosticsSection
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "figure.run")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.tint)
            Text("AARC")
                .font(.headline)
            Spacer()
            Text(AppVersion.build)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    /// Secondary connection/flight-recorder diagnostics — deliberately below
    /// the fold so the launch screen is just logo + version + start buttons.
    private var diagnosticsSection: some View {
        VStack(spacing: 8) {
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
            VStack(spacing: 8) {
                Text("AARC needs Health to track your runs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await requestHK() }
                } label: {
                    if requestingAuth {
                        ProgressView()
                    } else {
                        Label("Allow Health", systemImage: "heart.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }
        } else {
            // Slide-to-start (not tap) so a stray touch can't begin a run.
            VStack(spacing: 8) {
                WatchSlideToStart(label: "Treadmill", tint: .green,
                                  systemImage: "figure.run.treadmill") {
                    Task { await host.beginRun(runType: .treadmill,
                                               personalityId: "roast_coach",
                                               prepareScriptOnPhone: true) }
                }
                WatchSlideToStart(label: "Outdoor", tint: .blue,
                                  systemImage: "figure.run") {
                    Task { await host.beginRun(runType: .outdoor,
                                               personalityId: "roast_coach",
                                               prepareScriptOnPhone: true) }
                }
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
