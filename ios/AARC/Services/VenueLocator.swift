import AARCKit
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
    /// Internal (not private) so VenueProbeHarness can dry-run the REAL
    /// shipping path against a known address, not a reimplementation of it.
    func nearbyVenues(_ loc: CLLocation) async -> [String] {
        // DATUM — settled 2026-08-04 by dry-running the real search against
        // Park Hyatt Beijing's known coordinates (VenueProbeHarness), after
        // four runs where the founder's actual hotel never appeared:
        //
        //   search centre WGS-84 (raw CL fix) -> Park Hyatt @ 50m, RANK #1
        //   search centre GCJ-02 (what shipped) -> Park Hyatt @ 537m, rank #6,
        //                                          absent entirely at r<=1200
        //
        // MapKit takes WGS-84 and handles China's GCJ-02 offset internally, so
        // the previous "fix" was shifting the centre 548m AWAY from the runner
        // and then measuring distances from that wrong point. The shift is only
        // correct for DISPLAY (plotting a WGS trail onto an MKMapView, which is
        // GCJ-02 in China) — that is a different problem and RunMapView keeps
        // it. Searching and drawing are not the same coordinate space; the old
        // comment here conflated them. Do NOT re-add the transform.
        let center = loc
        // Hotels first (his usual venue is a hotel gym), then gyms; nearest
        // first within each. The old "酒店 hotel" keyword pass is GONE: the
        // probe showed it returns 25 hotels WITHOUT the target while adding
        // 1-2km impostors, and "柏悦" matched a Kashiwa 2,110km away. Category
        // lookup is language-independent and put the right venue first.
        // SEQUENTIAL, RETRIED, AND LOGGED — all three because of run 338384B7
        // (2026-08-04), where this returned FIVE gyms and ZERO hotels on device
        // while the identical code returned 17 hotels on the simulator from the
        // same coordinates.
        //
        // What the probe established: MKLocalPointsOfInterestRequest THROWS
        // when a category has no results (fitnessCenter threw 5/5 times near
        // Park Hyatt, hotels returned 17 every time, concurrent or not). So the
        // old `try?` collapsed "this category is empty here", "MapKit throttled
        // me" and "the network blipped" into one silent empty array — which is
        // why a whole run's venue card could come up wrong with nothing in the
        // log to say why. Root cause of the device/sim split is NOT yet proven;
        // this makes the next run say it out loud instead of guessing again.
        var ranked: [String] = []
        var diag: [String] = []
        for (label, cats) in [("hotel", [MKPointOfInterestCategory.hotel]),
                              ("gym", [MKPointOfInterestCategory.fitnessCenter])] {
            var r = await categoryVenues(cats, near: center)
            // One retry: a transient throttle/network failure is indistinguishable
            // from "genuinely nothing here", and retrying costs a second.
            if case .failure = r.outcome {
                try? await Task.sleep(for: .milliseconds(400))
                r = await categoryVenues(cats, near: center)
            }
            ranked += r.names
            diag.append("\(label)=\(r.names.count)\(r.note)")
        }
        // Keyword net when the category passes came up thin. Normally skipped:
        // the keyword search pulls in 1-2km impostors and misses the target by
        // name, so it is strictly a floor, never the primary source.
        if ranked.count < 3 {
            let kw = await searchNames("hotel gym fitness", near: center)
            ranked += kw
            diag.append("keyword=\(kw.count)")
        }
        RunEventLog.shared.record("venue.search", diag.joined(separator: " "))
        var seen = Set<String>()
        var names: [String] = []
        for name in ranked {
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
            if names.count == Self.maxCandidates { break }
        }
        return names
    }

    // Distance cap rationale: indoor GPS is coarse (~100-300m off) AND a big
    // hotel's map pin sits at its tower/entrance, not the gym — the TRUE venue
    // can read 400-600m away while you're standing inside it.
    //
    // Widened 1200 -> 3000 on 2026-08-04. With the datum bug fixed the true
    // venue now ranks FIRST, so a bigger net no longer risks burying it — it
    // just gives the confirm card a deep bench to keep asking from instead of
    // giving up after two questions (founder: "you give up too fast", wants to
    // keep going to ~20). The probe returned 17 hotels at r=3000 from the CBD.
    private static let maxVenueMeters: CLLocationDistance = 3000
    /// Founder's ask: keep offering until roughly 20 have been ruled out.
    static let maxCandidates = 20

    /// A category pass: the names, plus WHY the list is the size it is.
    /// `.failure` means MapKit threw — which for this API also happens on a
    /// genuinely empty category, so it is a retry hint, not proof of an error.
    struct CategoryResult {
        enum Outcome { case ok, failure(String) }
        let names: [String]
        let outcome: Outcome
        /// Compact suffix for the run log, e.g. "" or "(err:throttled)".
        var note: String {
            if case .failure(let why) = outcome { return "(err:\(why))" }
            return ""
        }
    }

    /// Category-based POI lookup: language-independent, name-independent.
    private func categoryVenues(_ cats: [MKPointOfInterestCategory], near loc: CLLocation) async -> CategoryResult {
        let req = MKLocalPointsOfInterestRequest(center: loc.coordinate, radius: Self.maxVenueMeters)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
        do {
            let resp = try await MKLocalSearch(request: req).start()
            return CategoryResult(names: rankedNames(resp.mapItems, near: loc), outcome: .ok)
        } catch {
            let why = (error as? MKError).map { "mk\($0.errorCode)" } ?? "other"
            return CategoryResult(names: [], outcome: .failure(why))
        }
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
