import SwiftUI
import AARCKit

/// In-session UI on the watch. Three pages, NRC-style:
/// - swipe left: Controls (pause / resume / end)
/// - center (default): Live metrics
/// - swipe right: Diagnostics
struct WatchActiveRunView: View {
    @Environment(WorkoutSessionHost.self) private var host
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPage: Page = .metrics
    @State private var showEndConfirm = false

    private enum Page: Hashable { case controls, metrics, diagnostics }

    var body: some View {
        TabView(selection: $selectedPage) {
            controlsPage.tag(Page.controls)
            metricsPage.tag(Page.metrics)
            diagnosticsPage.tag(Page.diagnostics)
        }
        .tabViewStyle(.page)
        // Pinned running-man animation across the top of every page while a
        // session is live. safeAreaInset reserves its own strip so all the
        // existing metrics below stay exactly where they were.
        .safeAreaInset(edge: .top, spacing: 0) {
            RunningManHeader(
                isRunning: host.state == .running,
                speedMps: speedMps(host.liveMetrics.currentPaceSecPerKm),
                cadenceSPM: host.liveMetrics.cadenceStepsPerMinute
            )
        }
        .navigationBarBackButtonHidden(true)
        .alert("End run?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("End", role: .destructive) {
                Task {
                    _ = await host.endRun()
                    dismiss()
                }
            }
        } message: {
            Text(host.currentRunIsTestData
                 ? "This is a test run. It will be tagged in Apple Health for easy cleanup."
                 : "This run will be permanently saved to Apple Health.")
        }
    }

    // MARK: - Controls (swipe left)

    private var controlsPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                modeBadge
                    .padding(.bottom, 4)

                if host.state == .running {
                    Button {
                        host.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .controlSize(.small)
                } else if host.state == .paused {
                    Button {
                        host.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }

                Button(role: .destructive) {
                    showEndConfirm = true
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)

                if host.state == .paused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            .padding()
        }
    }

    // MARK: - Metrics (default centre)

    private var metricsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                modeBadge
                    .padding(.bottom, 2)

                Text(formatElapsed(host.liveMetrics.elapsed))
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .monospacedDigit()

                Text(formatDistance(host.liveMetrics.distanceMeters))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    metric("Pace", value: formatPace(host.liveMetrics.currentPaceSecPerKm))
                    metric("HR", value: formatHR(host.liveMetrics.currentHeartRate))
                }
                .padding(.top, 4)

                HStack(spacing: 16) {
                    metric("Avg", value: formatPace(host.liveMetrics.avgPaceSecPerKm))
                    metric("kcal", value: "\(Int(host.liveMetrics.energyKcal))")
                }

                if host.state == .paused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            .padding()
        }
    }

    // MARK: - Diagnostics (swipe right)

    private var diagnosticsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Group {
                    diagRow("Sample event",
                            value: host.lastSampleEventAt.map { "\(secondsAgo($0))s ago" } ?? "never")
                    diagRow("Last types",
                            value: host.lastCollectedTypeShortNames.isEmpty
                                ? "—"
                                : host.lastCollectedTypeShortNames.joined(separator: ", "))
                }

                Divider().padding(.vertical, 2)

                Text("Sample counts")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(host.samplesPerType.sorted(by: { $0.key < $1.key }), id: \.key) { name, count in
                    diagRow(name, value: "\(count)")
                }
                if host.samplesPerType.isEmpty {
                    Text("none yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().padding(.vertical, 2)

                Text("Auth at start")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(host.hkAuthSnapshot.sorted(by: { $0.key < $1.key }), id: \.key) { name, status in
                    HStack {
                        Text(name).font(.caption2)
                        Spacer()
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(status == "sharingAuthorized" ? .green : .red)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var modeBadge: some View {
        let isIndoor = host.currentRunType == .treadmill
        Label(
            isIndoor ? "Treadmill" : "Outdoor",
            systemImage: isIndoor ? "figure.run.treadmill" : "figure.run"
        )
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.25), in: Capsule())
    }

    @ViewBuilder
    private func metric(_ label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func diagRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption2).monospacedDigit()
        }
    }

    private func secondsAgo(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date)))
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func formatPace(_ secPerKm: Double?) -> String {
        guard let s = secPerKm, s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return String(format: "%d:%02d", m, r)
    }

    private func formatHR(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "—" }
        return "\(Int(bpm))"
    }

    /// Forward speed in m/s from pace, for the running-man animation. 0 when
    /// there's no usable pace reading (the runner then idles gently).
    private func speedMps(_ secPerKm: Double?) -> Double {
        guard let s = secPerKm, s.isFinite, s > 0 else { return 0 }
        return 1000.0 / s
    }
}

// MARK: - Running man

/// A little runner who jogs in place at the top of the screen while a
/// session is live. The bob is DYNAMIC: the figure bobs once per real
/// footfall (driven by the watch's live cadence, falling back to a
/// pace-derived proxy), and the ground rushes past beneath it at a rate
/// set by the runner's actual speed. Fly and the legs spin up + the ground
/// blurs by; plod and it slackens. Freezes and dims when paused.
///
/// The phase is INTEGRATED frame-to-frame (`bobPhase += 2π·f·dt`) rather
/// than computed as `sin(absoluteTime × frequency)` — the latter would
/// scramble the phase the instant the cadence changed. Inputs are eased so
/// pace/cadence jitter doesn't make the runner twitch. Updates only while
/// running AND the screen is active, so there's no cost when the wrist
/// drops or it isn't on screen.
private struct RunningManHeader: View {
    let isRunning: Bool
    /// Forward speed in m/s (drives the ground rush + the pace fallback).
    let speedMps: Double
    /// Live cadence in steps/min from HealthKit, if available.
    let cadenceSPM: Double?

    @Environment(\.scenePhase) private var scenePhase

    /// Brighter than the brand's dark green so the runner pops on the black
    /// watch background.
    private let runnerColor = Color(red: 0.36, green: 0.82, blue: 0.46)
    private let stripHeight: CGFloat = 30
    private let dashGap: CGFloat = 15

    // Integrated animation state (kept small via wrap). Seeded to a lively
    // mid-run value so the runner starts moving immediately, then eases to
    // the real numbers.
    @State private var bobPhase: Double = 0
    @State private var groundPhase: Double = 0
    @State private var smoothedSpeed: Double = 2.6
    @State private var smoothedCadence: Double = 168
    @State private var lastTick: Date?

    @State private var tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            speedLines
            runner
        }
        .frame(maxWidth: .infinity)
        .frame(height: stripHeight)
        .background(Color.black)        // opaque so scrolling content can't peek behind
        .opacity(isRunning ? 1 : 0.45)  // dim when paused — the runner has stopped
        .accessibilityHidden(true)
        .onReceive(tick) { advance(to: $0) }
    }

    private var runner: some View {
        // A touch more bounce the faster you move — reads as effort.
        let amp = 2.0 + min(2.2, smoothedSpeed * 0.35)
        let bob = CGFloat(sin(bobPhase)) * CGFloat(amp)
        return Image(systemName: "figure.run")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(runnerColor)
            .shadow(color: runnerColor.opacity(0.55), radius: 4)
            .offset(y: bob)
    }

    private var speedLines: some View {
        Canvas { ctx, size in
            let len: CGFloat = 9
            let y = size.height * 0.62      // near the runner's feet
            let shift = CGFloat(groundPhase)
            var x = size.width - shift
            while x > -dashGap {
                let rect = CGRect(x: x - len, y: y, width: len, height: 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(runnerColor.opacity(0.45)))
                x -= dashGap
            }
        }
        .opacity(isRunning ? 1 : 0)
        // Soft fade at both edges so dashes appear / vanish gently.
        .mask(
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    /// One animation step: ease the inputs, then integrate the bob + ground
    /// phases by the elapsed time.
    private func advance(to now: Date) {
        guard isRunning, scenePhase == .active else {
            lastTick = nil          // resume cleanly next time
            return
        }
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        guard dt > 0, dt < 0.5 else { return }   // skip the first tick + any long gap

        let ease = min(1.0, dt / 0.7)            // ~0.7s time constant
        smoothedSpeed += (speedMps - smoothedSpeed) * ease
        let targetCadence = (cadenceSPM.map { $0 > 30 ? $0 : paceCadence } ?? paceCadence)
        smoothedCadence += (targetCadence - smoothedCadence) * ease

        bobPhase = (bobPhase + 2 * .pi * bobHz * dt)
            .truncatingRemainder(dividingBy: 2 * .pi)
        groundPhase = (groundPhase + groundPointsPerSecond * dt)
            .truncatingRemainder(dividingBy: Double(dashGap))
    }

    /// Bob frequency in Hz — one body bob per footfall.
    private var bobHz: Double {
        min(3.4, max(1.2, smoothedCadence / 60.0))
    }

    /// Pace-derived cadence proxy (steps/min) when HK cadence isn't there:
    /// ~150 shuffling up to ~190 flying.
    private var paceCadence: Double {
        min(195, max(145, 150 + smoothedSpeed * 12))
    }

    /// Ground scroll speed in points/sec — proportional to real speed, so
    /// faster running visibly blurs the ground past. Floored so it still
    /// drifts at a crawl.
    private var groundPointsPerSecond: Double {
        min(150, max(8, smoothedSpeed * 28))
    }
}

#Preview("Running fast") {
    RunningManHeader(isRunning: true, speedMps: 4.2, cadenceSPM: 182)
        .background(Color.black)
}

#Preview("Jogging") {
    RunningManHeader(isRunning: true, speedMps: 2.4, cadenceSPM: 158)
        .background(Color.black)
}

#Preview("Paused") {
    RunningManHeader(isRunning: false, speedMps: 0, cadenceSPM: nil)
        .background(Color.black)
}
