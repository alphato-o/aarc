import SwiftUI
import MapKit
import UIKit

/// Base map under the share-card route. Uses MKMapSnapshotter with the same
/// muted/label-light look as the in-app summary map (which renders fine in
/// China via the AutoNavi-backed tiles — CARTO/OSM were blocked). A LIGHT
/// green tint keeps streets visible (the old heavy `.color` blend washed the
/// map to black). The trail is projected into the snapshot's pixel space as
/// performance-colored segments so the video can draw them progressively.
///
/// Trail coords are display space (GCJ-02 in China) — MKMapSnapshotter renders
/// the matching tiles and `point(for:)` maps them straight in, no conversion.
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

        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = CGSize(width: width, height: height)
        opts.pointOfInterestFilter = .excludingAll
        if #available(iOS 17.0, *) {
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            opts.preferredConfiguration = c
        }
        guard let snapshot = try? await MKMapSnapshotter(options: opts).start() else { return nil }

        let base = UIGraphicsImageRenderer(size: opts.size).image { ctx in
            snapshot.image.draw(in: CGRect(origin: .zero, size: opts.size))
            // LIGHT on-brand wash (normal blend, low alpha) — keep streets legible.
            UIColor(red: 0.16, green: 0.24, blue: 0.18, alpha: 0.32).setFill()
            ctx.fill(CGRect(origin: .zero, size: opts.size))
        }

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
            segs.append(Segment(a: snapshot.point(for: coords[idx[j-1]]),
                                b: snapshot.point(for: coords[idx[j]]),
                                color: color(v, lo, hi, mode)))
        }
        return Result(image: base, segments: segs,
                      start: snapshot.point(for: coords[idx.first!]),
                      finish: snapshot.point(for: coords[idx.last!]))
    }

    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}
