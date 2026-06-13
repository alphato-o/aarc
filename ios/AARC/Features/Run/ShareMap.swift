import SwiftUI
import MapKit
import UIKit

/// Base map under the share-card route. Captures a LIVE offscreen MKMapView
/// (the same thing the summary map uses, which renders fine in China) rather
/// than MKMapSnapshotter — the snapshotter came back blank on-device. Muted
/// config + POIs off + a light green wash, dark appearance. The trail is
/// projected into the captured image's pixel space as performance-colored
/// segments so the video can draw them progressively.
///
/// Trail coords are display space (GCJ-02 in China); MKMapView renders the
/// matching tiles and `convert(_:toPointTo:)` maps them straight in.
enum ShareMap {
    struct Segment: Sendable { let a: CGPoint; let b: CGPoint; let color: Color }
    struct Result { let image: UIImage; let segments: [Segment]; let start: CGPoint?; let finish: CGPoint? }

    private final class RenderWaiter: NSObject, MKMapViewDelegate {
        var done: ((Bool) -> Void)?
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            done?(fullyRendered); done = nil
        }
    }

    @MainActor
    static func render(points: [PlaceContext.TrailPoint],
                       mode: RunMapView.ColorMode,
                       width: CGFloat, height: CGFloat) async -> Result? {
        let coords = points.map(\.coord)
        guard coords.count > 1 else { return nil }
        let region = RunMapView.boundingRegion(coords) ?? MKCoordinateRegion(
            center: coords[0], latitudinalMeters: 500, longitudinalMeters: 500)

        let size = CGSize(width: width, height: height)
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: size))
        mapView.overrideUserInterfaceStyle = .dark
        mapView.isUserInteractionEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsUserLocation = false
        if #available(iOS 17.0, *) {
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = c
        }
        mapView.setRegion(region, animated: false)

        // MKMapView only fetches tiles while it's in a window — attach it
        // offscreen, wait for the render-finished callback (with a timeout),
        // then capture.
        guard let window = keyWindow() else { return nil }
        mapView.frame = CGRect(x: -(width + 50), y: 0, width: width, height: height)
        window.addSubview(mapView)
        defer { mapView.removeFromSuperview() }

        let waiter = RenderWaiter()
        mapView.delegate = waiter
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            waiter.done = { _ in if !resumed { resumed = true; cont.resume() } }
            // Fallback: capture after 5s even if the callback never fires.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if !resumed { resumed = true; waiter.done = nil; cont.resume() }
            }
        }
        // One runloop tick so the final tiles commit before capture.
        try? await Task.sleep(for: .milliseconds(120))

        let captured = UIGraphicsImageRenderer(bounds: mapView.bounds).image { _ in
            mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true)
        }
        let base = UIGraphicsImageRenderer(size: size).image { ctx in
            captured.draw(in: CGRect(origin: .zero, size: size))
            UIColor(red: 0.16, green: 0.24, blue: 0.18, alpha: 0.30).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        func project(_ c: CLLocationCoordinate2D) -> CGPoint { mapView.convert(c, toPointTo: mapView) }

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

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
    }

    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}
