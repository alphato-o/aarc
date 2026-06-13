import SwiftUI
import CoreLocation
import UIKit

/// Builds the base map under the share-card route. Uses CARTO's `dark_nolabels`
/// raster tiles — real street SHAPES, zero labels (privacy), and a dark palette
/// that matches the card — composited into one image, with the trail projected
/// into that image's pixel space as performance-colored segments (so the video
/// can draw them progressively). MapKit was dropped here because it can't strip
/// street-name labels from a snapshot.
///
/// Tiles are WGS-84/web-mercator, so the display-space (GCJ-02) trail is
/// inverted back to WGS-84 first. If tiles can't be fetched (offline / blocked),
/// it falls back to a plain dark base so the route still renders.
enum ShareMap {
    struct Segment: Sendable { let a: CGPoint; let b: CGPoint; let color: Color }
    struct Result { let image: UIImage; let segments: [Segment]; let start: CGPoint?; let finish: CGPoint? }

    private static let tileSize: CGFloat = 256

    @MainActor
    static func render(points: [PlaceContext.TrailPoint],
                       mode: RunMapView.ColorMode,
                       width: CGFloat, height: CGFloat) async -> Result? {
        guard points.count > 1 else { return nil }
        // Display (GCJ) → WGS-84 for web-mercator tiles.
        let wgs = points.map { ChinaCoordinateTransform.wgsCoordinate(fromDisplay: $0.coord) }
        var minLat = wgs[0].latitude, maxLat = wgs[0].latitude
        var minLon = wgs[0].longitude, maxLon = wgs[0].longitude
        for c in wgs {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        // Pick a zoom so the padded route fills ~82% of the image.
        let pad = 1.22
        let lonSpan = max((maxLon - minLon) * pad, 0.0008)
        let latSpan = max((maxLat - minLat) * pad, 0.0008)
        var z = 18
        while z > 11 {
            let wpx = lonSpan / 360 * tileSize * pow(2, Double(z))
            let centerLat = (minLat + maxLat) / 2
            let hpx = latSpan / 360 * tileSize * pow(2, Double(z)) / cos(centerLat * .pi / 180)
            if wpx <= Double(width) && hpx <= Double(height) { break }
            z -= 1
        }
        let centerLat = (minLat + maxLat) / 2, centerLon = (minLon + maxLon) / 2
        // World-pixel origin of the image (top-left).
        let cpx = lonToWorldX(centerLon, z), cpy = latToWorldY(centerLat, z)
        let originX = cpx - Double(width) / 2, originY = cpy - Double(height) / 2

        func project(_ c: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: lonToWorldX(c.longitude, z) - originX,
                    y: latToWorldY(c.latitude, z) - originY)
        }

        let base = await compositeTiles(originX: originX, originY: originY,
                                        width: width, height: height, z: z)

        // Downsample + color the trail.
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
            segs.append(Segment(a: project(wgs[idx[j-1]]), b: project(wgs[idx[j]]),
                                color: color(v, lo, hi, mode)))
        }
        return Result(image: base, segments: segs,
                      start: project(wgs[idx.first!]), finish: project(wgs[idx.last!]))
    }

    // MARK: - tiles

    private static func compositeTiles(originX: Double, originY: Double,
                                       width: CGFloat, height: CGFloat, z: Int) async -> UIImage {
        let minTileX = Int(floor(originX / Double(tileSize)))
        let maxTileX = Int(floor((originX + Double(width)) / Double(tileSize)))
        let minTileY = Int(floor(originY / Double(tileSize)))
        let maxTileY = Int(floor((originY + Double(height)) / Double(tileSize)))
        let n = 1 << z

        // Fetch all needed tiles concurrently.
        var imagesByKey: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for tx in minTileX...maxTileX {
                for ty in minTileY...maxTileY {
                    let wrappedX = ((tx % n) + n) % n
                    guard ty >= 0, ty < n else { continue }
                    let key = "\(tx),\(ty)"
                    group.addTask { (key, await fetchTile(z: z, x: wrappedX, y: ty)) }
                }
            }
            for await (key, img) in group { if let img { imagesByKey[key] = img } }
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            UIColor(red: 0.05, green: 0.07, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for tx in minTileX...maxTileX {
                for ty in minTileY...maxTileY {
                    guard let img = imagesByKey["\(tx),\(ty)"] else { continue }
                    let px = Double(tx) * Double(tileSize) - originX
                    let py = Double(ty) * Double(tileSize) - originY
                    img.draw(in: CGRect(x: px, y: py, width: Double(tileSize), height: Double(tileSize)))
                }
            }
            // subtle green wash to sit it in the card's palette
            UIColor(red: 0.29, green: 0.39, blue: 0.31, alpha: 0.14).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func fetchTile(z: Int, x: Int, y: Int) async -> UIImage? {
        // dark, label-free street tiles — no key, matches the card.
        let url = URL(string: "https://a.basemaps.cartocdn.com/dark_nolabels/\(z)/\(x)/\(y)@2x.png")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        return img
    }

    // MARK: - web mercator (pixels at zoom z)

    private static func lonToWorldX(_ lon: Double, _ z: Int) -> Double {
        (lon + 180) / 360 * Double(tileSize) * pow(2, Double(z))
    }
    private static func latToWorldY(_ lat: Double, _ z: Int) -> Double {
        let s = sin(lat * .pi / 180)
        let y = 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
        return y * Double(tileSize) * pow(2, Double(z))
    }

    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}
