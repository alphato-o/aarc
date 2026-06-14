import SwiftUI
import UIKit

/// Base map under the share-card route.
///
/// The styled, label-free base map is rendered SERVER-side (`POST /staticmap`)
/// — the only reliable way to get map tiles into a bitmap in mainland China
/// (MKMapSnapshotter is blank there, on-device tile fetches are slow/blank).
/// The device fetches ONE image plus the projection params (zoom/origin) in
/// the response headers, then draws the performance-colored route on top
/// itself — full for the still, progressively for the video. So a 60s video is
/// local canvas frames over a single fetched image, not per-frame network.
enum ShareMap {
    struct Result {
        let image: UIImage      // styled base map (CARTO dark_nolabels + green tint)
        let points: [CGPoint]   // route polyline projected into the image's pixel space
        let colors: [Color]     // colors[i] = colour of segment points[i-1]→points[i]
    }

    /// Web-Mercator world pixel (tile=256), matching the server's projection.
    private static func world(_ lon: Double, _ lat: Double, _ z: Int) -> CGPoint {
        let n = 256.0 * pow(2.0, Double(z))
        let x = (lon + 180.0) / 360.0 * n
        let r = lat * .pi / 180.0
        let y = (1.0 - log(tan(r) + 1.0 / cos(r)) / .pi) / 2.0 * n
        return CGPoint(x: x, y: y)
    }

    static func render(points: [PlaceContext.TrailPoint],
                       mode: RunMapView.ColorMode,
                       width: CGFloat, height: CGFloat,
                       tileBase: String) async -> Result? {
        guard points.count > 1 else { return nil }
        // CARTO tiles are WGS-84; our trail is display space (GCJ in China) →
        // convert back to WGS so the route lines up on the server's tiles.
        let wgs = points.map { ChinaCoordinateTransform.wgsCoordinate(fromDisplay: $0.coord) }
        let vals = points.map { (mode == .pace ? $0.kmh : $0.hr) ?? 0 }

        let body: [String: Any] = [
            "w": Int(width), "h": Int(height),
            "mode": mode == .hr ? "hr" : "pace", "datum": "wgs",
            "points": zip(wgs, vals).map { [$0.0.longitude, $0.0.latitude, $0.1] },
        ]
        guard let url = URL(string: "\(tileBase)/staticmap"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let img = UIImage(data: data),
              let zStr = http.value(forHTTPHeaderField: "X-Map-Zoom"),
              let zoom = Int(zStr) else { return nil }
        let ox = Double(http.value(forHTTPHeaderField: "X-Map-Ox") ?? "") ?? 0
        let oy = Double(http.value(forHTTPHeaderField: "X-Map-Oy") ?? "") ?? 0

        // Project the route into the base image's pixel space (same formula +
        // origin the server used → it lands exactly on the tiles).
        let pxPts = wgs.map { c -> CGPoint in
            let w = world(c.longitude, c.latitude, zoom)
            return CGPoint(x: w.x - ox, y: w.y - oy)
        }
        let positive = vals.filter { $0 > 0 }
        let lo = positive.min() ?? 0, hi = positive.max() ?? 1
        let colors = vals.map { color($0, lo, hi, mode) }
        return Result(image: img, points: pxPts, colors: colors)
    }

    /// Performance hue for a value, shared by the live map and the share card.
    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.95)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.95)
    }
}
