import SwiftUI
import CoreLocation
import AARCKit

/// Brief post-run screen on the watch: the route (outdoor) + headline stats.
/// The rich summary lives on the phone; this is the glance-and-go version.
struct WatchRunSummary: View {
    let trail: [CLLocationCoordinate2D]
    let metrics: LiveMetrics
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if trail.count > 1 {
                    WatchRouteMap(trail: trail, live: false)
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 14) {
                    stat(String(format: "%.2f", metrics.distanceMeters / 1000), "KM")
                    stat(fmtDur(metrics.elapsed), "TIME")
                }
                if let p = metrics.currentPaceSecPerKm, p > 0 {
                    stat(fmtPace(metrics.avgPaceSecPerKm ?? p), "AVG /KM")
                }
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding(.horizontal, 6).padding(.vertical, 10)
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func fmtDur(_ s: TimeInterval) -> String {
        let t = Int(s); return t >= 3600
            ? String(format: "%d:%02d:%02d", t/3600, (t%3600)/60, t%60)
            : String(format: "%d:%02d", t/60, t%60)
    }
    private func fmtPace(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t/60, t%60)
    }
}
