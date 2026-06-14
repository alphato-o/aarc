import SwiftUI
import MapKit
import UIKit

/// Base map under the share-card route.
///
/// We can't capture Apple-Maps tiles to a bitmap in mainland China: MapKit
/// renders tiles OUT OF PROCESS (the system maps daemon composites them onto
/// the screen), so `drawHierarchy` — which only re-renders our own process's
/// layers — captures a blank map even when the map is visibly on screen. And
/// `MKMapSnapshotter`, the one in-process rasterizer, returns blank tiles in
/// China. Both Apple paths are dead ends here.
///
/// So we fetch map imagery we control: AutoNavi (高德) raster tiles. They're
/// GCJ-02 (our trail is already display/GCJ space, so it projects straight in
/// with standard Web-Mercator math), key-free, and served from inside China.
/// We stitch the covering tiles into the base image and draw the
/// performance-colored trail on top — entirely in-process, so it always lands
/// in the exported image.
enum ShareMap {
    struct Segment: Sendable { let a: CGPoint; let b: CGPoint; let color: Color }
    struct Result { let image: UIImage; let segments: [Segment]; let start: CGPoint?; let finish: CGPoint? }

    private static let tileSize = 256.0

    /// Web-Mercator world-pixel position of a coordinate at a zoom (tile=256).
    /// Fed GCJ-02 lon/lat to match the AutoNavi tile grid.
    private static func world(_ c: CLLocationCoordinate2D, _ z: Int) -> CGPoint {
        let n = tileSize * pow(2.0, Double(z))
        let x = (c.longitude + 180.0) / 360.0 * n
        let latRad = c.latitude * .pi / 180.0
        let y = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n
        return CGPoint(x: x, y: y)
    }

    static func render(points: [PlaceContext.TrailPoint],
                       mode: RunMapView.ColorMode,
                       width: CGFloat, height: CGFloat,
                       tileBase: String) async -> Result? {
        let coords = points.map(\.coord)        // display space (GCJ in China)
        guard coords.count > 1 else { return nil }
        let W = Double(width), H = Double(height)

        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        // Largest zoom at which the (padded) route still fits the image.
        var zoom = 3
        for z in stride(from: 19, through: 3, by: -1) {
            let tl = world(.init(latitude: maxLat, longitude: minLon), z)
            let br = world(.init(latitude: minLat, longitude: maxLon), z)
            if (br.x - tl.x) <= W * 0.84 && (br.y - tl.y) <= H * 0.84 { zoom = z; break }
        }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let cw = world(center, zoom)
        let originX = Double(cw.x) - W / 2, originY = Double(cw.y) - H / 2

        let minTX = Int(floor(originX / tileSize)), maxTX = Int(floor((originX + W) / tileSize))
        let minTY = Int(floor(originY / tileSize)), maxTY = Int(floor((originY + H) / tileSize))
        let maxIdx = Int(pow(2.0, Double(zoom))) - 1

        struct Tile: Sendable { let x: Int; let y: Int; let png: Data }
        var tiles: [Tile] = []
        await withTaskGroup(of: Tile?.self) { group in
            for tx in minTX...maxTX {
                for ty in minTY...maxTY {
                    guard tx >= 0, ty >= 0, tx <= maxIdx, ty <= maxIdx else { continue }
                    let z = zoom
                    group.addTask {
                        // Relayed through our proxy — AutoNavi serves blank
                        // tiles to a direct on-device request, but real tiles
                        // to the proxy's server-side fetch.
                        let str = "\(tileBase)/maptile?x=\(tx)&y=\(ty)&z=\(z)"
                        guard let url = URL(string: str),
                              let (data, _) = try? await URLSession.shared.data(from: url),
                              UIImage(data: data) != nil else { return nil }
                        return Tile(x: tx, y: ty, png: data)
                    }
                }
            }
            for await t in group { if let t { tiles.append(t) } }
        }
        guard !tiles.isEmpty else { return nil }

        let size = CGSize(width: width, height: height)
        let base = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.043, green: 0.055, blue: 0.047, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for t in tiles {
                guard let img = UIImage(data: t.png) else { continue }
                let r = CGRect(x: Double(t.x) * tileSize - originX,
                               y: Double(t.y) * tileSize - originY,
                               width: tileSize, height: tileSize)
                img.draw(in: r)
            }
            // AutoNavi style 7 is a LIGHT map; darken + brand it so the band
            // sits in the dark card instead of glaring out of it.
            UIColor(red: 0.05, green: 0.11, blue: 0.07, alpha: 0.52).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        func project(_ c: CLLocationCoordinate2D) -> CGPoint {
            let w = world(c, zoom)
            return CGPoint(x: Double(w.x) - originX, y: Double(w.y) - originY)
        }

        let step = max(1, points.count / 160)
        var idx: [Int] = []
        var i = 0
        while i < points.count { idx.append(i); i += step }
        if idx.last != points.count - 1 { idx.append(points.count - 1) }
        let vals = idx.compactMap { mode == .pace ? points[$0].kmh : points[$0].hr }.filter { $0 > 0 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        var segs: [Segment] = []
        for j in 1..<idx.count {
            let v = (mode == .pace ? points[idx[j]].kmh : points[idx[j]].hr) ?? 0
            segs.append(Segment(a: project(coords[idx[j - 1]]), b: project(coords[idx[j]]),
                                color: color(v, lo, hi, mode)))
        }
        return Result(image: base, segments: segs,
                      start: project(coords[idx.first!]), finish: project(coords[idx.last!]))
    }

    /// Performance hue for a value, shared by the live map and the share card.
    static func color(_ v: Double, _ lo: Double, _ hi: Double, _ mode: RunMapView.ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)
        return mode == .pace
            ? Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)
            : Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92)
    }
}
