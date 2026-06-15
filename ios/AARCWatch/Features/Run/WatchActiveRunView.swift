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
    @Environment(WatchSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPage: Page = .metrics
    @State private var showEndConfirm = false
    @State private var showSummary = false
    /// Coach line the runner dismissed (X) — hidden until the next line.
    @State private var coachDismissedId: UUID?

    private enum Page: Hashable { case controls, metrics, map, chart, diagnostics }

    var body: some View {
        TabView(selection: $selectedPage) {
            controlsPage.tag(Page.controls)
            metricsPage.tag(Page.metrics)
            if host.currentRunType == .outdoor {
                mapPage.tag(Page.map)
            }
            chartPage.tag(Page.chart)
            diagnosticsPage.tag(Page.diagnostics)
        }
        .tabViewStyle(.page)
        // Coach line OVERLAYS the current screen the moment one lands (like the
        // phone) — no need to swipe to a separate page to heart it.
        .overlay { coachOverlay }
        .animation(.easeInOut(duration: 0.22), value: session.currentCoachLine?.id)
        .navigationBarBackButtonHidden(true)
        .alert("End run?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("End", role: .destructive) {
                if host.isSimDisplay {
                    // Desk-sim mirror: no HK session. End the local display +
                    // tell the phone to end its sim; the phone shows the summary.
                    session.sendStateEvent(.endWorkout)
                    host.endSimDisplay()
                } else {
                    // Show the post-run summary INSTANTLY (it reads in-memory
                    // data, no wait). The slow HealthKit teardown runs in the
                    // background so the tap never feels dropped.
                    showSummary = true
                    Task { _ = await host.endRun() }
                }
            }
        } message: {
            Text(host.currentRunIsTestData
                 ? "This is a test run. It will be tagged in Apple Health for easy cleanup."
                 : "This run will be permanently saved to Apple Health.")
        }
        .fullScreenCover(isPresented: $showSummary, onDismiss: { dismiss() }) {
            WatchRunSummary(points: host.routeTrailPoints, metrics: host.liveMetrics) {
                showSummary = false
            }
        }
    }

    // MARK: - Coach overlay (heart the current line, over the main screen)

    @ViewBuilder
    private var coachOverlay: some View {
        if let line = session.currentCoachLine, line.id != coachDismissedId {
            WatchCoachPage(
                line: line.text,
                who: line.who,
                stampSecondsAgo: max(0, Int(Date().timeIntervalSince(line.receivedAt))),
                hearted: session.heartedLineIds.contains(line.id),
                onHeart: { session.heartCurrentLine() },
                onDismiss: { coachDismissedId = line.id }
            )
            .background(.black.opacity(0.9))
            .transition(.opacity)
        }
    }

    // MARK: - Chart (live HR + speed)

    private var chartPage: some View {
        WatchChartPage(
            samples: host.chartSamples,
            elapsed: host.liveMetrics.elapsed,
            currentHR: host.liveMetrics.currentHeartRate,
            distanceMeters: host.liveMetrics.distanceMeters
        )
    }

    // MARK: - Map (outdoor only)

    private var mapPage: some View {
        ZStack(alignment: .bottomLeading) {
            if host.routeTrailPoints.isEmpty {
                ContentUnavailableView("Finding you\u{2026}", systemImage: "location.magnifyingglass")
            } else {
                WatchRouteMap(points: host.routeTrailPoints, mode: .pace).ignoresSafeArea()
            }
            Text("\(String(format: "%.2f", host.liveMetrics.distanceMeters / 1000)) km")
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(8)
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

    // MARK: - Metrics (default centre)

    private var metricsPage: some View {
        WatchMetricsView(metrics: host.liveMetrics, runType: host.currentRunType)
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
struct RunnerBadge: View {
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
