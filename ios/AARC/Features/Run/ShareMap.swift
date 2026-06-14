import SwiftUI
import MapKit
import UIKit

/// Base map under the share-card route. Renders the tiles with
/// `MKMapSnapshotter` — the purpose-built "map → UIImage" API. (The old
/// approach captured an offscreen MKMapView with `drawHierarchy`, which never
/// captured the Metal-rendered tile layer and so came back blank — the route
/// drew but the map behind it didn't.) Muted config + POIs off + a green
/// wash, dark appearance. The trail is projected into the snapshot's pixel
/// space via `snapshot.point(for:)` as performance-colored segments, so the
/// video can draw them progressively.
///
/// Trail coords are display space (GCJ-02 in China); the snapshotter renders
/// the matching tiles and projects display coords straight in.
enum ShareMap {
    struct Segment: Sendable { let a: CGPoint; let b: CGPoint; let color: Color }
    struct Result { let image: UIImage; let segments: [Segment]; let start: CGPoint?; let finish: CGPoint? }

    @MainActor
    static func render(points: [PlaceContext.TrailPoint],
                       mode: RunMapView.ColorMode,
                       width: CGFloat, height: CGFloat) async -> Result? {
        let coords = points.map(\.coord)
        guard coords.count > 1 else { return nil }
        let region = RunMapView.boundingRegion(coords) ?? MKCoordinateRegion(
            center: coords[0], latitudinalMeters: 500, longitudinalMeters: 500)

        let size = CGSize(width: width, height: height)
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        if #available(iOS 17.0, *) {
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = c
        } else {
            options.mapType = .standard
            options.pointOfInterestFilter = .excludingAll
        }

        // Retained across the await so the operation isn't cancelled.
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot: MKMapSnapshotter.Snapshot
        do { snapshot = try await snapshotter.start() }
        catch { return nil }

        let base = UIGraphicsImageRenderer(size: size).image { ctx in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            UIColor(red: 0.16, green: 0.24, blue: 0.18, alpha: 0.30).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        // `snapshot.point(for:)` maps a coordinate into the image's pixel
        // space (origin top-left, sized to `options.size`).
        func project(_ c: CLLocationCoordinate2D) -> CGPoint { snapshot.point(for: c) }

        let stride = max(1, points.count / 160)
        var idx: [Int] = []
        var i = 0
        while i < points.count { idx.append(i); i += stride }
        if idx.last != points.count - 1 { idx.append(points.count - 1) }
        let vals = idx.compactMap { mode == .pace ? points[$0].kmh : points[$0].hr }.filter { $0 > 0 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        var segs: [Segment] = []
        for j in 1..<idx.count {
            let v = (mode == .pace ? points[idx[j]].kmh : points[idx[j]].hr) ?? 0
            segs.append(Segment(a: project(coords[idx[j-1]]), b: project(coords[idx[j]]),
                                color: color(v, lo, hi, mode)))
        }
        return Result(image: base, segments: segs,
                      start: project(coords[idx.first!]), finish: project(coords[idx.last!]))
    }

    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}
