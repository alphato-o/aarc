import SwiftUI
import AARCKit

/// In-session UI on the watch. Three pages, NRC / Apple-Workout style:
/// - swipe left: Controls (pause / resume / end)
/// - center (default): Live metrics — Apple's clean left-aligned metric
///   stack (big colour-coded numbers, small caps unit labels), with an
///   ACTUAL articulated running figure as the workout badge top-left.
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
        .navigationBarBackButtonHidden(true)
        .alert("End run?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("End", role: .destructive) {
                // Dismiss INSTANTLY so the tap registers. The HealthKit
                // teardown (endCollection/finishWorkout/finishRoute) is
                // slow and used to freeze the screen for a beat, reading
                // as a missed tap. Run it in the background after dismiss.
                dismiss()
                Task { _ = await host.endRun() }
            }
        } message: {
            Text(host.currentRunIsTestData
                 ? "This is a test run. It will be tagged in Apple Health for easy cleanup."
                 : "This run will be permanently saved to Apple Health.")
        }
    }

    // MARK: - Controls (swipe left)

    private var controlsPage: some View {
        VStack(spacing: 12) {
            if host.state == .running {
                Button {
                    host.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
            } else if host.state == .paused {
                Button {
                    host.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            Button(role: .destructive) {
                showEndConfirm = true
            } label: {
                Label("End", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            if host.state == .paused {
                Text("PAUSED")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.yellow.opacity(0.3), in: Capsule())
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Metrics (default centre) — Apple Workout layout

    private var metricsPage: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Workout badge top-left, exactly where Apple puts the workout
            // icon — but it's a real runner mid-stride, not a static glyph.
            HStack(spacing: 6) {
                RunnerBadge(
                    isRunning: host.state == .running,
                    speedMps: speedMps(host.liveMetrics.currentPaceSecPerKm),
                    cadenceSPM: host.liveMetrics.cadenceStepsPerMinute,
                    indoor: host.currentRunType == .treadmill
                )
                if host.state == .paused {
                    Text("PAUSED")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.yellow)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            // Elapsed — the hero number, Apple-yellow.
            Text(formatElapsed(host.liveMetrics.elapsed))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.98, green: 0.83, blue: 0.18))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            metricRow(formatHR(host.liveMetrics.currentHeartRate), "BPM",
                      color: .white, heart: true)
            metricRow(formatPace(host.liveMetrics.currentPaceSecPerKm), "PACE",
                      color: Color(red: 0.36, green: 0.85, blue: 0.55))
            metricRow(formatPace(host.liveMetrics.avgPaceSecPerKm), "AVG PACE",
                      color: .white.opacity(0.85))
            metricRow(formatDistanceValue(host.liveMetrics.distanceMeters),
                      formatDistanceUnit(host.liveMetrics.distanceMeters), color: .white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
    }

    /// One Apple-style metric line: big value, small caps unit to the right,
    /// optional heart. Baseline-aligned so the unit sits on the number's foot.
    @ViewBuilder
    private func metricRow(_ value: String, _ unit: String, color: Color, heart: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            if heart {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .baselineOffset(1)
            }
            Text(unit)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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

    private func formatDistanceValue(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f", meters / 1000) : String(format: "%.0f", meters)
    }

    private func formatDistanceUnit(_ meters: Double) -> String {
        meters >= 1000 ? "KM" : "M"
    }

    private func formatPace(_ secPerKm: Double?) -> String {
        guard let s = secPerKm, s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return String(format: "%d'%02d\"", m, r)
    }

    private func formatHR(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "—" }
        return "\(Int(bpm))"
    }

    /// Forward speed in m/s from pace, for the running figure. 0 when there's
    /// no usable pace reading (the runner then idles gently).
    private func speedMps(_ secPerKm: Double?) -> Double {
        guard let s = secPerKm, s.isFinite, s > 0 else { return 0 }
        return 1000.0 / s
    }
}

// MARK: - Runner badge

/// The workout indicator, top-left, Apple-style — but instead of a static
/// `figure.run` glyph it's a SECOND-BY-SECOND ARTICULATED runner: head,
/// leaning torso, two pumping arms and two striding legs that cycle through
/// a real run gait. The stride rate tracks the watch's live cadence (falling
/// back to a pace-derived proxy) and the lean/bounce grow with speed, so it
/// reads as actual running, not a bobbing pictogram. Freezes + dims when
/// paused; only animates while running AND on-screen, so it costs nothing
/// wrist-down.
private struct RunnerBadge: View {
    let isRunning: Bool
    let speedMps: Double
    let cadenceSPM: Double?
    let indoor: Bool

    @Environment(\.scenePhase) private var scenePhase

    private let runnerColor = Color(red: 0.36, green: 0.85, blue: 0.50)
    private let diameter: CGFloat = 34

    // Integrated gait state. Seeded mid-stride + lively so it's already
    // running the instant it appears, then eases to the real numbers.
    @State private var phase: Double = 0
    @State private var smoothedSpeed: Double = 2.6
    @State private var smoothedCadence: Double = 170
    @State private var lastTick: Date?
    @State private var tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { ctx, size in
            drawRunner(in: &ctx, size: size)
        }
        .frame(width: diameter, height: diameter)
        .background(runnerColor.opacity(0.18), in: Circle())
        .overlay(Circle().strokeBorder(runnerColor.opacity(0.30), lineWidth: 1))
        .opacity(isRunning ? 1 : 0.5)
        .accessibilityHidden(true)
        .onReceive(tick) { advance(to: $0) }
    }

    // MARK: Gait drawing

    private func drawRunner(in ctx: inout GraphicsContext, size: CGSize) {
        let s = size.width / 34.0            // scale to the design's 34pt box
        let p = phase

        // Bounce: two footfalls per stride, so the body rises/dips at 2×.
        let bounce = -CGFloat(abs(sin(p))) * 2.0 * s
        // Forward lean grows a touch with speed — effort reads in the torso.
        let lean = 0.30 + min(0.14, smoothedSpeed * 0.02)

        // Hip anchor, centred, sat low so the legs have room beneath.
        let hip = CGPoint(x: size.width * 0.46, y: size.height * 0.56 + bounce)

        // Limb lengths.
        let torsoLen = 9.5 * s, thigh = 7.2 * s, shin = 6.8 * s
        let upperArm = 5.2 * s, foreArm = 5.0 * s, headR = 3.0 * s
        let limbW = 3.1 * s

        // angle 0 = straight down (+y); positive = forward (+x).
        func pt(_ o: CGPoint, _ len: CGFloat, _ a: Double) -> CGPoint {
            CGPoint(x: o.x + len * CGFloat(sin(a)), y: o.y + len * CGFloat(cos(a)))
        }
        func limb(_ a: CGPoint, _ b: CGPoint, _ color: GraphicsContext.Shading) {
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path, with: color, style: StrokeStyle(lineWidth: limbW, lineCap: .round))
        }

        let near = GraphicsContext.Shading.color(runnerColor)
        let far = GraphicsContext.Shading.color(runnerColor.opacity(0.5))

        // Torso + head, leaning forward.
        let shoulder = CGPoint(x: hip.x + CGFloat(sin(lean)) * torsoLen,
                               y: hip.y - CGFloat(cos(lean)) * torsoLen)
        let head = CGPoint(x: shoulder.x + CGFloat(sin(lean)) * (headR + 1.5 * s),
                           y: shoulder.y - CGFloat(cos(lean)) * (headR + 1.5 * s))

        // One leg: thigh swings ±stride; the knee flexes to lift the foot on
        // the back-swing / recovery and extends to reach on the front-swing.
        func leg(_ legPhase: Double, _ shade: GraphicsContext.Shading) {
            let stride = 0.95
            let thighA = lean * 0.35 + stride * sin(legPhase)
            let knee = pt(hip, thigh, thighA)
            let flex = 0.22 + 1.05 * max(0, -sin(legPhase)) + 0.35 * max(0, -cos(legPhase))
            let foot = pt(knee, shin, thighA - flex)
            limb(hip, knee, shade)
            limb(knee, foot, shade)
        }

        // One arm: shoulder swings opposite the same-side leg; elbow stays
        // bent ~90°+ as a runner's does.
        func arm(_ armPhase: Double, _ shade: GraphicsContext.Shading) {
            let swing = 0.72
            let shoulderA = lean * 0.5 + swing * sin(armPhase)
            let elbow = pt(shoulder, upperArm, shoulderA)
            let hand = pt(elbow, foreArm, shoulderA + 1.25 + 0.25 * sin(armPhase))
            limb(shoulder, elbow, shade)
            limb(elbow, hand, shade)
        }

        // Depth order: far limbs first (dimmer), then body, then near limbs.
        leg(p + .pi, far)
        arm(p, far)

        limb(hip, shoulder, near)                       // torso
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - headR, y: head.y - headR,
                                        width: headR * 2, height: headR * 2)),
                 with: near)                            // head

        leg(p, near)
        arm(p + .pi, near)
    }

    // MARK: Animation step

    private func advance(to now: Date) {
        guard isRunning, scenePhase == .active else { lastTick = nil; return }
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        guard dt > 0, dt < 0.5 else { return }

        let ease = min(1.0, dt / 0.7)
        smoothedSpeed += (speedMps - smoothedSpeed) * ease
        let targetCadence = cadenceSPM.map { $0 > 30 ? $0 : paceCadence } ?? paceCadence
        smoothedCadence += (targetCadence - smoothedCadence) * ease

        // One full gait cycle = two footfalls, so stride frequency = cadence/2.
        let strideHz = min(1.9, max(0.8, smoothedCadence / 120.0))
        phase = (phase + 2 * .pi * strideHz * dt).truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// Pace-derived cadence proxy (steps/min) when HK cadence isn't there.
    private var paceCadence: Double { min(195, max(150, 152 + smoothedSpeed * 12)) }
}

#Preview("Running fast") {
    RunnerBadge(isRunning: true, speedMps: 4.2, cadenceSPM: 182, indoor: true)
        .padding()
        .background(Color.black)
}

#Preview("Jogging") {
    RunnerBadge(isRunning: true, speedMps: 2.4, cadenceSPM: 158, indoor: false)
        .padding()
        .background(Color.black)
}
