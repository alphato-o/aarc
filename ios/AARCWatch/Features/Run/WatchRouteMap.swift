import SwiftUI
import CoreLocation

/// Lightweight self-drawn route map for the watch — no MapKit tiles (cheap
/// on battery during a workout). Draws the trail traced so far and a flashing
/// dot at the current position, auto-fitted to the screen. Used live (with
/// the pulse) and post-run (static, full route).
struct WatchRouteMap: View {
    var trail: [CLLocationCoordinate2D]
    var live: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: live ? 0.1 : 3600)) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate
            let pulseR: CGFloat = live ? 5 + 4 * CGFloat(0.5 + 0.5 * sin(phase * 3)) : 6
            canvas(pulseR: pulseR)
        }
    }

    private func canvas(pulseR: CGFloat) -> some View {
        Canvas { ctx, size in
            guard trail.count > 1 else {
                if let p = trail.first {
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    _ = p
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                             with: .color(.blue))
                }
                return
            }
            // Fit lat/lon to the canvas, preserving aspect (lat shrinks by cos).
            var minLat = trail[0].latitude, maxLat = trail[0].latitude
            var minLon = trail[0].longitude, maxLon = trail[0].longitude
            for c in trail {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
            let latMid = (minLat + maxLat) / 2
            let lonScale = cos(latMid * .pi / 180)
            let spanX = max((maxLon - minLon) * lonScale, 1e-6)
            let spanY = max(maxLat - minLat, 1e-6)
            let pad: CGFloat = 14
            let scale = min((size.width - pad * 2) / spanX, (size.height - pad * 2) / spanY)
            let offX = (size.width - spanX * scale) / 2
            let offY = (size.height - spanY * scale) / 2
            func pt(_ c: CLLocationCoordinate2D) -> CGPoint {
                CGPoint(x: offX + (c.longitude - minLon) * lonScale * scale,
                        y: offY + (maxLat - c.latitude) * scale)
            }
            var path = Path()
            path.move(to: pt(trail[0]))
            for c in trail.dropFirst() { path.addLine(to: pt(c)) }
            ctx.stroke(path, with: .color(Color(red: 1.0, green: 0.55, blue: 0.30)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            // start dot
            let s = pt(trail[0])
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)),
                     with: .color(.white.opacity(0.5)))
            // current position (pulsing when live)
            let cur = pt(trail[trail.count - 1])
            ctx.fill(Path(ellipseIn: CGRect(x: cur.x - pulseR, y: cur.y - pulseR, width: pulseR * 2, height: pulseR * 2)),
                     with: .color(.blue.opacity(0.35)))
            ctx.fill(Path(ellipseIn: CGRect(x: cur.x - 4, y: cur.y - 4, width: 8, height: 8)),
                     with: .color(.blue))
        }
    }
}
