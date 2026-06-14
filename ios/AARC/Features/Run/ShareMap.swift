import SwiftUI
import MapKit
import UIKit

/// Base map under the share-card route.
///
/// Capturing Apple-Maps tiles to a bitmap is the hard part in mainland China:
/// `MKMapSnapshotter` returns blank there, and an OFFSCREEN `MKMapView` never
/// composites its Metal tile layer, so `drawHierarchy` on it captured nothing
/// either. The thing that DOES render China tiles is a live, on-screen map —
/// the very map the run-summary screen shows.
///
/// So we reuse exactly that: `CapturableRouteMap` is a real `MKMapView`,
/// visible on screen in the share composer, with the performance-colored trail
/// drawn as overlays. Once it finishes rendering we capture it (it's on-screen,
/// so the tiles are present) and hand the baked image to the card.
enum ShareMap {
    struct Segment: Sendable { let a: CGPoint; let b: CGPoint; let color: Color }
    struct Result { let image: UIImage; let segments: [Segment]; let start: CGPoint?; let finish: CGPoint? }

    /// Performance hue for a value, shared by the live map and the share card.
    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}

/// A `MKPolyline` that carries its own stroke color (MKPolyline has none).
private final class ColoredPolyline: MKPolyline {
    var strokeUIColor: UIColor = .green
}

/// Live, on-screen map for the share composer. Renders the route as
/// performance-colored segments over real Apple-Maps tiles, and — once the
/// tiles have actually drawn — captures itself to a UIImage (with the on-brand
/// green wash) and reports it via `onCaptured`. Capturing an on-screen map is
/// what makes the tiles show up in China, where the offscreen/snapshot paths
/// come back blank.
struct CapturableRouteMap: UIViewRepresentable {
    let points: [PlaceContext.TrailPoint]
    let mode: RunMapView.ColorMode
    let onCaptured: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = false
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        map.showsCompass = false
        map.showsScale = false
        if #available(iOS 17.0, *) {
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = c
        }
        map.delegate = context.coordinator
        context.coordinator.map = map
        context.coordinator.mode = mode
        configure(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Re-render when the color mode changes (the composer toggles Pace/HR).
        if context.coordinator.mode != mode {
            context.coordinator.mode = mode
            context.coordinator.captured = false
            map.removeOverlays(map.overlays)
            configure(map)
        }
    }

    private func configure(_ map: MKMapView) {
        let coords = points.map(\.coord)
        guard coords.count > 1 else { return }
        let segs = RunMapView.coloredSegments(points, mode: mode)
        for s in segs {
            let pl = ColoredPolyline(coordinates: [s.a, s.b], count: 2)
            pl.strokeUIColor = UIColor(s.color)
            map.addOverlay(pl, level: .aboveLabels)
        }
        if let region = RunMapView.boundingRegion(coords) {
            map.setRegion(region, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onCaptured: (UIImage) -> Void
        weak var map: MKMapView?
        var mode: RunMapView.ColorMode = .pace
        var captured = false

        init(onCaptured: @escaping (UIImage) -> Void) { self.onCaptured = onCaptured }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let p = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: p)
                r.strokeColor = p.strokeUIColor
                r.lineWidth = 5
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard !captured, fullyRendered else { return }
            captured = true
            // One beat after "fully rendered" so the final tiles + overlays
            // commit to the on-screen layer before we snapshot it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak mapView] in
                guard let mapView, mapView.bounds.width > 0 else { return }
                let img = UIGraphicsImageRenderer(bounds: mapView.bounds).image { ctx in
                    mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true)
                    // On-brand green wash over Apple's tiles (can't recolor them).
                    UIColor(red: 0.16, green: 0.24, blue: 0.18, alpha: 0.28).setFill()
                    ctx.fill(mapView.bounds)
                }
                self.onCaptured(img)
            }
        }
    }
}
