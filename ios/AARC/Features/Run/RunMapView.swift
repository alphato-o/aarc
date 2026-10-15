import SwiftUI
import MapKit
import CoreLocation

/// Live route + POI map for outdoor runs. The trail is hued by performance
/// (NRC-style) — pace or heart rate, toggled — drawn as short colored
/// segments. POIs are tinted markers (hotels pink, rest teal); a pulsing dot
/// marks the runner. The base map is decluttered (POI labels off) with a
/// translucent green wash so it reads on-brand; Apple won't let us repaint
/// the tiles themselves.
///
/// Everything handed in is already in Apple-Maps display space (GCJ-02 in
/// mainland China), so it plots without further transform.
struct RunMapView: View {
    var points: [PlaceContext.TrailPoint]
    var current: CLLocationCoordinate2D?
    var pois: [PlaceContext.POIPin]
    var plannedRoute: [CLLocationCoordinate2D] = []
    var follow: Bool = false
    var showsColorToggle: Bool = false
    /// Strip the map back as far as MapKit allows: muted emphasis (faint
    /// roads, minimal labels) + heavier green wash, the route as the only
    /// thing that pops. Used post-run. (MapKit can't fully remove road
    /// labels like Nike's custom tiles — this is the closest stock can get.)
    var minimalChrome: Bool = false

    enum ColorMode: String { case pace, hr }
    @State private var mode: ColorMode = .pace
    @State private var camera: MapCameraPosition = .automatic

    private var segments: [(coords: [CLLocationCoordinate2D], color: Color)] {
        Self.coloredSegments(points, mode: mode)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $camera, interactionModes: follow ? [] : .all) {
                if plannedRoute.count > 1 {
                    MapPolyline(coordinates: plannedRoute)
                        .stroke(.gray.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    MapPolyline(coordinates: seg.coords)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(pois) { poi in
                    Marker(poi.name, systemImage: poi.symbol, coordinate: poi.coordinate)
                        .tint(poi.isHotel ? .pink : .teal)
                }
                if let current {
                    Annotation("", coordinate: current) {
                        ZStack {
                            Circle().fill(.blue.opacity(0.25)).frame(width: 26, height: 26)
                            Circle().fill(.blue).frame(width: 13, height: 13)
                                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat,
                                emphasis: minimalChrome ? .muted : .automatic,
                                pointsOfInterest: .excludingAll, showsTraffic: false))
            // On-brand green wash — can't recolor Apple's tiles, so tint over them.
            Color(red: 0.29, green: 0.39, blue: 0.31).opacity(minimalChrome ? 0.30 : 0.18)
                .blendMode(.color).allowsHitTesting(false)

            if showsColorToggle {
                Picker("", selection: $mode) {
                    Text("Pace").tag(ColorMode.pace)
                    Text("HR").tag(ColorMode.hr)
                }
                .pickerStyle(.segmented).frame(width: 130).padding(8)
            }
        }
        .onChange(of: regionKey) { _, _ in updateCamera() }
        .onAppear { updateCamera() }
    }

    private var regionKey: String {
        let c = current.map { "\(Int($0.latitude * 4000)),\(Int($0.longitude * 4000))" } ?? "-"
        return "\(c)|\(points.count / 5)|\(pois.count)|\(plannedRoute.count)"
    }

    private func updateCamera() {
        if follow, let current {
            camera = .region(MKCoordinateRegion(center: current,
                                                latitudinalMeters: 700, longitudinalMeters: 700))
            return
        }
        var pts = points.map(\.coord) + plannedRoute + pois.map(\.coordinate)
        if let current { pts.append(current) }
        camera = Self.boundingRegion(pts).map { .region($0) } ?? .automatic
    }

    // MARK: - Performance coloring

    /// Every trail point is drawn (a 200 m park loop must look like a loop,
    /// not a polygon: the old ~140-segment downsample kept one point per
    /// 60-70 m). Overlay count is bounded by grouping consecutive points into
    /// runs of one colour bucket, so a 10 km run is a few dozen polylines.
    static func coloredSegments(_ points: [PlaceContext.TrailPoint], mode: ColorMode)
        -> [(coords: [CLLocationCoordinate2D], color: Color)] {
        guard points.count > 1 else { return [] }
        let raw: [Double] = points.map { (mode == .pace ? $0.kmh : $0.hr) ?? 0 }
        // Light smoothing so the colour does not flicker point to point.
        var vals = raw
        if raw.count > 5 {
            for i in 0..<raw.count {
                let lo = max(0, i - 2), hi = min(raw.count - 1, i + 2)
                let window = raw[lo...hi].filter { $0 > 0 }
                vals[i] = window.isEmpty ? 0 : window.reduce(0, +) / Double(window.count)
            }
        }
        let present = vals.filter { $0 > 0 }
        let lo = present.min() ?? 0, hi = present.max() ?? 1
        func bucket(_ v: Double) -> Int {
            guard v > 0, hi > lo else { return -1 }
            return min(9, Int(((v - lo) / (hi - lo)) * 10))
        }
        var out: [(coords: [CLLocationCoordinate2D], color: Color)] = []
        var current: [CLLocationCoordinate2D] = [points[0].coord]
        var currentBucket = bucket(vals[1])
        for j in 1..<points.count {
            let b = bucket(vals[j])
            if b != currentBucket {
                out.append((current, color(for: bucketValue(currentBucket, lo: lo, hi: hi), lo: lo, hi: hi, mode: mode)))
                current = [points[j - 1].coord]
                currentBucket = b
            }
            current.append(points[j].coord)
        }
        out.append((current, color(for: bucketValue(currentBucket, lo: lo, hi: hi), lo: lo, hi: hi, mode: mode)))
        return out
    }

    private static func bucketValue(_ b: Int, lo: Double, hi: Double) -> Double {
        b < 0 ? 0 : lo + (Double(b) + 0.5) / 10 * (hi - lo)
    }

    private static func color(for v: Double, lo: Double, hi: Double, mode: ColorMode) -> Color {
        guard v > 0, hi > lo else { return Color(red: 0.66, green: 0.78, blue: 0.69) }
        let t = (v - lo) / (hi - lo)            // 0…1
        switch mode {
        case .pace:  return Color(hue: 0.33 * t, saturation: 0.85, brightness: 0.92)  // slow=red → fast=green
        case .hr:    return Color(hue: 0.62 * (1 - t), saturation: 0.85, brightness: 0.92) // low=blue → high=red
        }
    }

    static func boundingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.004))
        return MKCoordinateRegion(center: center, span: span)
    }
}
