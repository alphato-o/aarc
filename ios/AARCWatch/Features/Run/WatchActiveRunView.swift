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
            RunningManHeader(isRunning: host.state == .running)
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
}

// MARK: - Running man

/// A little runner who jogs in place at the top of the screen while a
/// session is live: the figure bobs at a running cadence and the ground
/// rushes past beneath it (leftward speed lines), so it reads as forward
/// motion without leaving its spot. Freezes and dims when paused.
///
/// Driven by a TimelineView so the loop is seamless and self-pausing — the
/// system also stops it automatically when the wrist drops / the display
/// goes always-on, so there's no battery cost when it isn't being watched.
private struct RunningManHeader: View {
    let isRunning: Bool

    /// Brighter than the brand's dark green so the runner pops on the black
    /// watch background.
    private let runnerColor = Color(red: 0.36, green: 0.82, blue: 0.46)
    private let stripHeight: CGFloat = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRunning)) { timeline in
            // Absolute time → periodic phase; no stored start date needed.
            let t = isRunning ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                if isRunning {
                    speedLines(t: t)
                }
                runner(t: t)
            }
            .frame(maxWidth: .infinity)
            .frame(height: stripHeight)
        }
        .frame(height: stripHeight)
        .background(Color.black)        // opaque so scrolling content can't peek behind
        .opacity(isRunning ? 1 : 0.45)  // dim when paused — the runner has stopped
        .accessibilityHidden(true)
    }

    private func runner(t: TimeInterval) -> some View {
        // ~2.6 footfalls/sec body bob — a natural running cadence.
        let bob = CGFloat(sin(t * 2 * .pi * 2.6)) * 2.5
        return Image(systemName: "figure.run")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(runnerColor)
            .shadow(color: runnerColor.opacity(0.55), radius: 4)
            .offset(y: bob)
    }

    private func speedLines(t: TimeInterval) -> some View {
        Canvas { ctx, size in
            let gap: CGFloat = 15
            let speed: Double = 85          // points/sec, scrolling left
            let len: CGFloat = 9
            let y = size.height * 0.62      // near the runner's feet
            let shift = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(gap)))
            var x = size.width - shift
            while x > -gap {
                let rect = CGRect(x: x - len, y: y, width: len, height: 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(runnerColor.opacity(0.45)))
                x -= gap
            }
        }
        // Soft fade at both edges so dashes appear / vanish gently.
        .mask(
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }
}

#Preview("Running") {
    RunningManHeader(isRunning: true)
        .background(Color.black)
}

#Preview("Paused") {
    RunningManHeader(isRunning: false)
        .background(Color.black)
}
