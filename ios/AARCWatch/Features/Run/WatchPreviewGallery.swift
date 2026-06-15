import SwiftUI
import CoreLocation
import AARCKit

/// Env-gated screenshot harness (AARC_PREVIEW=<screen>) so the in-run pages can
/// be verified on the simulator with mock data — no live run/phone needed.
/// Never reachable in production (the env var is never set there).
struct WatchPreviewGallery: View {
    let screen: String

    var body: some View {
        switch screen {
        case "coach":
            WatchCoachPage(line: "Call that a hill? My nan jogs faster, and she's carrying the shopping.",
                           who: "ricky", stampSecondsAgo: 8, hearted: false) {}
        case "coach_long":
            WatchCoachPage(line: "Right, listen. Your pace just fell off a cliff and your form's gone with it. Shoulders back, drive the arms, and stop checking your watch every four seconds, you twitchy little metronome — the data's not getting better while you stare at it.",
                           who: "jessica", stampSecondsAgo: 12, hearted: false) {}
        case "coach_hearted":
            WatchCoachPage(line: "Call that a hill? My nan jogs faster.",
                           who: "ricky", stampSecondsAgo: 8, hearted: true) {}
        case "coach_empty":
            WatchCoachPage(line: nil, who: nil, stampSecondsAgo: nil, hearted: false) {}
        case "coach_overlay":
            ZStack {
                WatchMetricsView(metrics: Self.mockMetrics(.running), runType: .treadmill)
                WatchCoachPage(line: "Call that a hill? My nan jogs faster, and she's carrying the shopping.",
                               who: "ricky", stampSecondsAgo: 4, hearted: false, onHeart: {}, onDismiss: {})
                    .background(.black.opacity(0.9))
            }
        case "metrics":
            WatchMetricsView(metrics: Self.mockMetrics(.running), runType: .treadmill)
        case "metrics_paused":
            WatchMetricsView(metrics: Self.mockMetrics(.paused), runType: .outdoor)
        case "chart":
            WatchChartPage(samples: Self.mockSamples, elapsed: 1458, currentHR: 152, distanceMeters: 2410)
        case "simrun":
            // Drive the host into a sim-display mirror, then show the real
            // in-run UI so the sim path can be screenshot-verified solo.
            WatchActiveRunView()
                .onAppear {
                    let h = WorkoutSessionHost.shared
                    h.startSimDisplay(runId: UUID(), runType: .outdoor)
                    h.ingestSimMetrics(Self.mockMetrics(.running))
                    let t = Self.mockTrailPoints
                    h.ingestSimTrail(lats: t.map { $0.coord.latitude }, lons: t.map { $0.coord.longitude },
                                     kmh: t.map { $0.kmh }, hr: t.map { $0.hr })
                }
        case "map":
            // Mirrors WatchActiveRunView.mapPage (outdoor): self-drawn trail +
            // pulsing position + a distance capsule.
            ZStack(alignment: .bottomLeading) {
                WatchRouteMap(points: Self.mockTrailPoints, mode: .pace).ignoresSafeArea()
                Text("2.41 km")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(8)
            }
        default:
            Text("unknown preview: \(screen)")
        }
    }

    /// A recognizable looping trail (a park-ish loop) for the map preview,
    /// with varying speed so the hue ramp is visible. Coords are display-space.
    static var mockTrailPoints: [WatchTrailPoint] {
        let cx = 39.9075, cy = 116.447
        var out: [WatchTrailPoint] = []
        for i in 0..<70 {
            let t = Double(i) / 70 * 2 * .pi
            let r = 0.004 * (1 + 0.35 * sin(t * 3))
            out.append(WatchTrailPoint(
                coord: .init(latitude: cx + r * sin(t) * 0.7, longitude: cy + r * cos(t)),
                kmh: 9 + 4 * sin(t * 2.5), hr: nil))
        }
        return out
    }

    static func mockMetrics(_ state: WorkoutState) -> LiveMetrics {
        LiveMetrics(elapsed: 1458, distanceMeters: 3410, currentPaceSecPerKm: 342,
                    avgPaceSecPerKm: 358, currentHeartRate: 152, energyKcal: 287,
                    cadenceStepsPerMinute: 174, lastSplit: nil, state: state)
    }

    static var mockSamples: [WatchChartSample] {
        var out: [WatchChartSample] = []
        for i in 0..<44 {
            let d = Double(i)
            let hr: Double = 120 + 34 * sin(d / 5.0) + d * 0.5
            let kmh: Double = 9 + 3 * sin(d / 3.0)
            out.append(WatchChartSample(hr: hr, kmh: kmh))
        }
        return out
    }
}
