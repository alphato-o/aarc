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

    /// Returns (coord, city, venues) — city may be nil, venues may be empty.
    /// `venues` is the nearby hotels/gyms ranked nearest-first, so the in-run
    /// confirm popup can walk them ("Are you at X? / Y? / Z?") instead of
    /// asserting one wrong guess. We DON'T pick one as fact here — the runner
    /// confirms, which is the whole point (a wrong venue kills the vibe).
    func capture() async -> (coord: CLLocationCoordinate2D, city: String?, venues: [String])? {
        guard let loc = await oneShot() else { return nil }
        async let city = reverseCity(loc)
        async let venues = nearbyVenues(loc)
        return (loc.coordinate, await city, await venues)
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

    /// Up to 5 nearby hotels/gyms, ranked nearest-first, de-duped by name.
    /// A slightly wider radius (500m) than the old single-guess (350m) so the
    /// actual venue (e.g. a hotel gym set back from the road) makes the list.
    private func nearbyVenues(_ loc: CLLocation) async -> [String] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "hotel gym fitness"
        req.region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 500, longitudinalMeters: 500)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        // MKLocalSearch's region is only a HINT — it returns POIs far outside it
        // (the field bug: "Kerry Hotel" was a real venue MILES away, offered as
        // if the runner could be in it). Hard-cap to a distance you could
        // plausibly be STANDING IN — a building/immediate block — so we never ask
        // "are you at X?" about somewhere it's physically impossible to be.
        let maxMeters: CLLocationDistance = 400
        let near = resp.mapItems
            .compactMap { item -> (String, CLLocationDistance)? in
                guard let name = item.name,
                      let d = item.placemark.location?.distance(from: loc),
                      d <= maxMeters else { return nil }
                return (name, d)
            }
            .sorted { $0.1 < $1.1 }
        var seen = Set<String>()
        var names: [String] = []
        for (name, _) in near {
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
            if names.count == 5 { break }
        }
        return names
    }
}
