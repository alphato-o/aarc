import SwiftUI
import MapKit
import CoreLocation

/// A trail vertex with the performance at that point (display/GCJ-space coord).
struct WatchTrailPoint: Identifiable {
    let id = UUID()
    let coord: CLLocationCoordinate2D
    let kmh: Double?
    let hr: Double?
}

enum WatchTrailColorMode { case pace, hr }

/// In-run route map on the watch — REAL Apple-Maps tiles (so you can see where
/// you are), with the trail hued by performance (pace or HR) like the phone.
/// Coordinates are already display-space (GCJ in China) so they sit on the
/// tiles. Follows the runner with a close zoom.
struct WatchRouteMap: View {
    var points: [WatchTrailPoint]
    var mode: WatchTrailColorMode = .pace
    var follow: Bool = true

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        // No pan/zoom — the map follows the runner, and a static map lets the
        // page-swipe through (an interactive map would trap the screen).
        Map(position: $camera, interactionModes: []) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                MapPolyline(coordinates: [seg.a, seg.b])
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let cur = points.last?.coord {
                Annotation("", coordinate: cur) {
                    ZStack {
                        Circle().fill(.blue.opacity(0.3)).frame(width: 22, height: 22)
                        Circle().fill(.blue).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .onChange(of: regionKey) { _, _ in updateCamera() }
        .onAppear { updateCamera() }
    }

    private var regionKey: String {
        guard let c = points.last?.coord else { return "-" }
        return "\(Int(c.latitude * 3000)),\(Int(c.longitude * 3000))|\(points.count / 4)"
    }

    private func updateCamera() {
        guard let cur = points.last?.coord else { return }
        if follow {
            camera = .region(MKCoordinateRegion(center: cur,
                                                latitudinalMeters: 600, longitudinalMeters: 600))
        } else if let region = boundingRegion(points.map(\.coord)) {
            camera = .region(region)   // post-run: fit the whole route
        }
    }

    private func boundingRegion(_ cs: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = cs.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in cs {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.4, 0.003),
                        longitudeDelta: max((maxLon - minLon) * 1.4, 0.003)))
    }

    // MARK: - Performance-hued segments

    private struct Seg { let a: CLLocationCoordinate2D; let b: CLLocationCoordinate2D; let color: Color }

    private var segments: [Seg] {
        guard points.count > 1 else { return [] }
        let vals = points.compactMap { mode == .pace ? $0.kmh : $0.hr }.filter { $0 > 0 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        var out: [Seg] = []
        for i in 1..<points.count {
            let v = (mode == .pace ? points[i].kmh : points[i].hr) ?? 0
            out.append(Seg(a: points[i - 1].coord, b: points[i].coord, color: color(v, lo, hi)))
        }
        return out
    }

    private func color(_ v: Double, _ lo: Double, _ hi: Double) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.95)        // slow red → fast green
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.95)  // low blue → high red
    }
}
