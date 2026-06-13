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

    enum ColorMode: String { case pace, hr }
    @State private var mode: ColorMode = .pace
    @State private var camera: MapCameraPosition = .automatic

    private var segments: [(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, color: Color)] {
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
                    MapPolyline(coordinates: [seg.a, seg.b])
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
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
            // On-brand green wash — can't recolor Apple's tiles, so tint over them.
            Color(red: 0.29, green: 0.39, blue: 0.31).opacity(0.18)
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

    static func coloredSegments(_ points: [PlaceContext.TrailPoint], mode: ColorMode)
        -> [(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, color: Color)] {
        guard points.count > 1 else { return [] }
        // Downsample to ~140 segments so we don't spawn hundreds of overlays.
        let stride = max(1, points.count / 140)
        var reduced: [PlaceContext.TrailPoint] = []
        var i = 0
        while i < points.count { reduced.append(points[i]); i += stride }
        if reduced.last?.coord.latitude != points.last?.coord.latitude { reduced.append(points[points.count - 1]) }

        let vals = reduced.compactMap { mode == .pace ? $0.kmh : $0.hr }.filter { $0 > 0 }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        var out: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Color)] = []
        for j in 1..<reduced.count {
            let v = (mode == .pace ? reduced[j].kmh : reduced[j].hr) ?? 0
            out.append((reduced[j-1].coord, reduced[j].coord, color(for: v, lo: lo, hi: hi, mode: mode)))
        }
        return out
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
