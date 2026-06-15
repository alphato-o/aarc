import SwiftUI
import CoreLocation

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
        case "chart":
            WatchChartPage(samples: Self.mockSamples, elapsed: 1458, currentHR: 152, distanceMeters: 2410)
        case "map":
            // Mirrors WatchActiveRunView.mapPage (outdoor): self-drawn trail +
            // pulsing position + a distance capsule.
            ZStack(alignment: .bottomLeading) {
                WatchRouteMap(trail: Self.mockTrail, live: true).ignoresSafeArea()
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

    /// A recognizable looping trail (a park-ish loop) for the map preview.
    static var mockTrail: [CLLocationCoordinate2D] {
        let cx = 39.9075, cy = 116.447
        var out: [CLLocationCoordinate2D] = []
        for i in 0..<70 {
            let t = Double(i) / 70 * 2 * .pi
            let r = 0.004 * (1 + 0.35 * sin(t * 3))   // wobbly loop
            out.append(.init(latitude: cx + r * sin(t) * 0.7,
                             longitude: cy + r * cos(t)))
        }
        return out
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
