import SwiftUI
import MapKit
import CoreLocation

/// Live route + POI map for outdoor runs. Draws the planned route faintly
/// (simulated runs only), the trail travelled so far brightly, named POIs
/// as tinted markers (hotels pink, the rest teal), and a pulsing dot at the
/// runner's current position.
///
/// Everything it's handed is already in Apple-Maps display space (GCJ-02
/// inside mainland China), so it plots without any further transform.
struct RunMapView: View {
    var trail: [CLLocationCoordinate2D]
    var current: CLLocationCoordinate2D?
    var pois: [PlaceContext.POIPin]
    var plannedRoute: [CLLocationCoordinate2D] = []
    /// Follow the runner with a fixed span instead of fitting the whole
    /// route. Off (fit-all) suits the post-run summary; on suits live.
    var follow: Bool = false

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera, interactionModes: follow ? [] : .all) {
            if plannedRoute.count > 1 {
                MapPolyline(coordinates: plannedRoute)
                    .stroke(.gray.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
            }
            if trail.count > 1 {
                MapPolyline(coordinates: trail)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
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
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onChange(of: regionKey) { _, _ in updateCamera() }
        .onAppear { updateCamera() }
    }

    /// Cheap change-token so the camera only recomputes when the geometry
    /// meaningfully moves (every appended trail point would thrash it).
    private var regionKey: String {
        let c = current.map { "\(Int($0.latitude * 4000)),\(Int($0.longitude * 4000))" } ?? "-"
        return "\(c)|\(trail.count / 5)|\(pois.count)|\(plannedRoute.count)"
    }

    private func updateCamera() {
        if follow, let current {
            camera = .region(MKCoordinateRegion(
                center: current,
                latitudinalMeters: 700, longitudinalMeters: 700))
            return
        }
        var pts = trail + plannedRoute + pois.map(\.coordinate)
        if let current { pts.append(current) }
        guard let region = Self.boundingRegion(pts) else { camera = .automatic; return }
        camera = .region(region)
    }

    static func boundingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.004))
        return MKCoordinateRegion(center: center, span: span)
    }
}
