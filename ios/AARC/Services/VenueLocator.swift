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

    /// Up to 6 nearby venues, ranked nearest-first, de-duped by name.
    ///
    /// v3 of this search, built on three runs of failure data. The keyword
    /// query ("hotel") matches POIs by NAME — so budget chains literally
    /// named "…Hotel Branch" outrank a luxury hotel whose Chinese POI name
    /// (e.g. 柏悦酒店-style names on China's map data) doesn't score on the
    /// English word at all. Fix: CATEGORY-based lookup
    /// (MKLocalPointsOfInterestRequest, .hotel/.fitnessCenter) — matches by
    /// what a place IS, language-independent, no venue names baked anywhere.
    /// Keyword search stays as a bilingual fallback. Category hotels first
    /// (the founder's usual venue is a hotel gym), then category gyms, then
    /// keyword stragglers; nearest-first within each group.
    private func nearbyVenues(_ loc: CLLocation) async -> [String] {
        async let catHotels = categoryVenues([.hotel], near: loc)
        async let catGyms = categoryVenues([.fitnessCenter], near: loc)
        async let kw = searchNames("酒店 hotel", near: loc)
        let ranked = (await catHotels) + (await catGyms) + (await kw)
        var seen = Set<String>()
        var names: [String] = []
        for name in ranked {
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
            if names.count == 6 { break }
        }
        return names
    }

    // Distance cap rationale: indoor GPS is coarse (~100-300m off) AND a big
    // hotel's map pin sits at its tower/entrance, not the gym — the TRUE venue
    // can read 400-600m away while you're standing inside it. 1200m clears that
    // headroom while still excluding the km-away impostors (the "Kerry Hotel
    // from miles away" field bug). The runner confirms; we never assert.
    private static let maxVenueMeters: CLLocationDistance = 1200

    /// Category-based POI lookup: language-independent, name-independent.
    private func categoryVenues(_ cats: [MKPointOfInterestCategory], near loc: CLLocation) async -> [String] {
        let req = MKLocalPointsOfInterestRequest(center: loc.coordinate, radius: Self.maxVenueMeters)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return rankedNames(resp.mapItems, near: loc)
    }

    private func searchNames(_ query: String, near loc: CLLocation) async -> [String] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 2500, longitudinalMeters: 2500)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return rankedNames(resp.mapItems, near: loc)
    }

    /// Hard-cap by ACTUAL distance (the request region/radius is only a hint)
    /// and sort nearest-first.
    private func rankedNames(_ items: [MKMapItem], near loc: CLLocation) -> [String] {
        items
            .compactMap { item -> (String, CLLocationDistance)? in
                guard let name = item.name,
                      let d = item.placemark.location?.distance(from: loc),
                      d <= Self.maxVenueMeters else { return nil }
                return (name, d)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}
