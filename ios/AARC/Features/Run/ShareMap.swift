import SwiftUI
import MapKit
import UIKit

/// Renders a static, on-brand base map of the run's route for the share card,
/// plus the trail as performance-colored segments in the image's pixel space
/// (so the card can draw them progressively for the video). MapKit tiles
/// can't be recolored, so we bake a muted snapshot + green wash + dark
/// vignette and lay the bright colored trail on top.
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
        opts.scale = 1
        opts.pointOfInterestFilter = .excludingAll
        if #available(iOS 17.0, *) {
            opts.preferredConfiguration = {
                let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                c.pointOfInterestFilter = .excludingAll
                return c
            }()
        }

        guard let snapshot = try? await MKMapSnapshotter(options: opts).start() else { return nil }

        // Bake the base: muted map + green wash + dark vignette.
        let baseRenderer = UIGraphicsImageRenderer(size: opts.size)
        let baseImage = baseRenderer.image { ctx in
            snapshot.image.draw(in: CGRect(origin: .zero, size: opts.size))
            UIColor(red: 0.29, green: 0.39, blue: 0.31, alpha: 0.28).setFill()
            ctx.cgContext.setBlendMode(.color)
            ctx.fill(CGRect(origin: .zero, size: opts.size))
            ctx.cgContext.setBlendMode(.normal)
            UIColor(white: 0, alpha: 0.18).setFill()
            ctx.fill(CGRect(origin: .zero, size: opts.size))
        }

        // Downsample + color the trail in image space.
        let stride = max(1, points.count / 160)
        var reduced: [PlaceContext.TrailPoint] = []
        var i = 0
        while i < points.count { reduced.append(points[i]); i += stride }
        if reduced.last?.coord.latitude != points.last?.coord.latitude { reduced.append(points[points.count - 1]) }

        let vals = reduced.compactMap { mode == .pace ? $0.kmh : $0.hr }.filter { $0 > 0 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        var segs: [Segment] = []
        for j in 1..<reduced.count {
            let v = (mode == .pace ? reduced[j].kmh : reduced[j].hr) ?? 0
            segs.append(Segment(a: snapshot.point(for: reduced[j-1].coord),
                                b: snapshot.point(for: reduced[j].coord),
                                color: color(v, lo, hi, mode)))
        }
        return Result(image: baseImage, segments: segs,
                      start: reduced.first.map { snapshot.point(for: $0.coord) },
                      finish: reduced.last.map { snapshot.point(for: $0.coord) })
    }

    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}
