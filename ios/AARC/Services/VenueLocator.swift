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

    /// Up to 5 nearby venues, ranked nearest-first, de-duped by name.
    ///
    /// TWO searches, because one can't cover both worlds: the gym-category
    /// query ("hotel gym fitness") returns GYM POIs, and a hotel's own gym is
    /// not separately indexed — two real runs proved Park Hyatt never appears
    /// while its neighbours' fitness centres do. So a second query surfaces
    /// nearby HOTELS by name; hotel results rank first (the founder's usual
    /// venue is a hotel gym), then gyms, all nearest-first within each group.
    private func nearbyVenues(_ loc: CLLocation) async -> [String] {
        async let hotels = searchNames("hotel", near: loc)
        async let gyms = searchNames("hotel gym fitness", near: loc)
        let ranked = (await hotels) + (await gyms)
        var seen = Set<String>()
        var names: [String] = []
        for name in ranked {
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
            if names.count == 5 { break }
        }
        return names
    }

    private func searchNames(_ query: String, near loc: CLLocation) async -> [String] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 2500, longitudinalMeters: 2500)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        // Hard-cap by ACTUAL distance so we never ask "are you at X?" about a
        // venue that's physically impossible to be in (MKLocalSearch's region is
        // only a hint — it returned "Kerry Hotel" from MILES away). But the cap
        // must survive real error: indoor GPS is coarse (~100-300m off) AND a big
        // hotel's map pin sits at its tower/entrance, not the gym — so the TRUE
        // venue can read 400-600m away while you're standing in it. 1000m clears
        // that headroom (real venue makes the list) while still excluding the
        // km-away impostors. The runner confirms the right one from the list.
        let maxMeters: CLLocationDistance = 1000
        return resp.mapItems
            .compactMap { item -> (String, CLLocationDistance)? in
                guard let name = item.name,
                      let d = item.placemark.location?.distance(from: loc),
                      d <= maxMeters else { return nil }
                return (name, d)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}
