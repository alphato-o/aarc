import CoreLocation
import MapKit

/// One-shot coarse location → city + nearest prominent venue, for treadmill
/// runs (indoors, no continuous GPS). Deliberately separate from
/// `PlaceContext`'s continuous tracking so it never appends to the outdoor
/// trail or logs `gps` events — a treadmill run must not grow a route.
@MainActor
final class VenueLocator: NSObject, CLLocationManagerDelegate {
    static let shared = VenueLocator()
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Returns (coord, city, venue) — any of which may be nil. venue is the
    /// nearest hotel/gym, the "wild but likely guess" (e.g. Park Hyatt gym).
    func capture() async -> (coord: CLLocationCoordinate2D, city: String?, venue: String?)? {
        guard let loc = await oneShot() else { return nil }
        async let city = reverseCity(loc)
        async let venue = nearestVenue(loc)
        return (loc.coordinate, await city, await venue)
    }

    private func oneShot() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        guard manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways else { return nil }
        return await withCheckedContinuation { c in
            cont = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        Task { @MainActor in cont?.resume(returning: locs.last); cont = nil }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in cont?.resume(returning: nil); cont = nil }
    }

    private func reverseCity(_ loc: CLLocation) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc)
        return marks?.first?.locality ?? marks?.first?.subAdministrativeArea
    }

    private func nearestVenue(_ loc: CLLocation) async -> String? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "hotel gym fitness"
        req.region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 350, longitudinalMeters: 350)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return nil }
        let nearest = resp.mapItems.min {
            ($0.placemark.location?.distance(from: loc) ?? .greatestFiniteMagnitude)
                < ($1.placemark.location?.distance(from: loc) ?? .greatestFiniteMagnitude)
        }
        return nearest?.name
    }
}
