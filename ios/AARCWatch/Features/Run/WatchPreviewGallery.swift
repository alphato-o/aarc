import SwiftUI

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
        default:
            Text("unknown preview: \(screen)")
        }
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
