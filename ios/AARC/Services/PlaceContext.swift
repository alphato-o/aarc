import Foundation
import CoreLocation
import MapKit
import OSLog

/// Live "where is the runner" context for OUTDOOR runs: the actual road,
/// neighbourhood and nearby named POIs, fed into every reactive line so the
/// coaches ground their material in real surroundings instead of inventing
/// cargo-shorts men and imaginary shrubs.
///
/// Sources — no API keys, both work in mainland China (Apple's geo services
/// there are backed by AutoNavi data):
///   - `CLGeocoder` reverse geocoding → road + area names. Takes the raw
///     WGS-84 fix; Apple handles the China datum internally.
///   - `MKLocalPointsOfInterestRequest` → named POIs around the runner.
///     MapKit's search space inside mainland China is GCJ-02, so the search
///     centre goes through ChinaCoordinateTransform first — without the
///     shift every POI query lands ~500 m off (see the route-map fix).
///
/// Hotels sort first by design: a prominent hotel within sight is prime
/// persona material. Sampling is cheap relative to an active GPS workout:
/// one geocode + one POI search per ~300 m / 120 s, whichever first.
@MainActor
@Observable
final class PlaceContext: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceContext()

    struct Snapshot {
        var road: String?
        var area: String?
        var pois: [String]      // "The PuLi (hotel, 140m)" — preformatted
        var asOf: Date
    }

    private(set) var snapshot: Snapshot?
    private(set) var isActive = false
    /// Simulated mode: fixes come from RunSimulator's synthetic route via
    /// `ingestSimulated` instead of CLLocationManager — the rest of the
    /// pipeline (geocode, POI, route shape, LLM payloads) runs unchanged,
    /// which is the whole point: desk-verify the real machinery.
    private(set) var isSimulated = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastFix: CLLocation?
    private var lastFixAt: Date?
    private var refreshing = false
    private let log = Logger(subsystem: "club.aarun.AARC", category: "PlaceContext")

    /// Categories worth a coach line. Order is irrelevant here — ranking
    /// happens in `nearbyPOIs` (hotels first, then by distance).
    private static let categories: [MKPointOfInterestCategory] = [
        .hotel, .nightlife, .brewery, .winery, .restaurant, .cafe, .bakery,
        .park, .fitnessCenter, .stadium, .theater, .museum,
    ]

    /// Geometry of the run so far. Detects the classic exercise patterns —
    /// laps of a small park track, circling a block, out-and-back — from
    /// the GPS trail, using the start point as the lap anchor (an exercise
    /// loop almost always passes back through where it began).
    private struct RouteShape {
        private var origin: CLLocation?
        private var last: CLLocation?
        private var cumDist: Double = 0
        private var maxFromOrigin: Double = 0
        private var fromOriginNow: Double = 0
        // lap detection: re-entering a 35m disc around the start after
        // having been >80m away, with >200m travelled since last crossing
        private var awayFromOrigin = false
        private var distAtLastCrossing: Double = 0
        private var lapLengths: [Double] = []
        // turnaround detection for out-and-back
        private var peakFromOrigin: Double = 0
        private var distAtPeak: Double = 0

        mutating func reset() { self = RouteShape() }

        mutating func add(_ loc: CLLocation) {
            guard let originLoc = origin else { origin = loc; last = loc; return }
            guard let lastLoc = last else { last = loc; return }
            let step = loc.distance(from: lastLoc)
            guard step >= 10 else { return }   // ignore jitter
            cumDist += step
            last = loc
            let r = loc.distance(from: originLoc)
            fromOriginNow = r
            if r > maxFromOrigin { maxFromOrigin = r }
            if r > peakFromOrigin { peakFromOrigin = r; distAtPeak = cumDist }
            if r > 80 { awayFromOrigin = true }
            if awayFromOrigin, r < 35 {
                let leg = cumDist - distAtLastCrossing
                if leg > 200 { lapLengths.append(leg) }
                distAtLastCrossing = cumDist
                awayFromOrigin = false
                peakFromOrigin = 0
                distAtPeak = cumDist
            }
        }

        /// One human sentence, or nil when the shape is still ambiguous —
        /// better to say nothing than describe a pattern that isn't there.
        var routeDescription: String? {
            if !lapLengths.isEmpty {
                let sorted = lapLengths.sorted()
                let lap = sorted[sorted.count / 2]
                let len = max(Int((lap / 50).rounded() * 50), 100)
                return "circling the same ~\(len)m loop, on lap \(lapLengths.count + 1) now"
            }
            if peakFromOrigin >= 400, cumDist - distAtPeak > 150,
               fromOriginNow < peakFromOrigin * 0.8 {
                let out = Int((peakFromOrigin / 100).rounded() * 100)
                return "out-and-back: turned around ~\(out)m out, now heading back toward the start"
            }
            if cumDist > 800, maxFromOrigin > cumDist * 0.6 {
                return "point-to-point so far, not looping"
            }
            return nil
        }
    }

    private var routeShape = RouteShape()

    override private init() {
        super.init()
        manager.delegate = self
        // Ten-metre accuracy + 20m updates: lap detection on a ~400m park
        // track needs real geometry; 100m-grade fixes can't see the loop.
        // The GPS radio is already hot for the workout, so the marginal
        // battery cost is small.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Begin sampling. Call when an OUTDOOR run starts (never for
    /// treadmill or the desk simulator — fabricated scenery is exactly
    /// what this exists to kill, not relocate).
    func start() {
        guard !isActive else { return }
        isActive = true
        isSimulated = false
        snapshot = nil
        lastFix = nil
        lastFixAt = nil
        routeShape.reset()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // "location" is declared in UIBackgroundModes; the audio session
        // keeps the app alive during runs anyway — this is belt & braces
        // so fixes keep flowing with the screen locked.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        log.info("[place] sampling started")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if !isSimulated {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
        isSimulated = false
        geocoder.cancelGeocode()
        log.info("[place] sampling stopped")
    }

    /// Begin a SIMULATED session: same state machine, no GPS hardware.
    /// RunSimulator injects synthetic fixes along its generated route.
    func startSimulated() {
        guard !isActive else { return }
        isActive = true
        isSimulated = true
        snapshot = nil
        lastFix = nil
        lastFixAt = nil
        routeShape.reset()
        log.info("[place] SIMULATED sampling started")
    }

    /// Synthetic fix from the desk simulator. Ignored outside simulation.
    func ingestSimulated(_ loc: CLLocation) {
        guard isActive, isSimulated else { return }
        consider(loc)
    }

    /// Live route-shape readout for the Control Room diagnosis panel.
    var routeDescriptionNow: String? { routeShape.routeDescription }

    /// Compact payload for the LLM endpoints. nil when inactive, empty,
    /// or stale (>5 min old — better no context than wrong context).
    var llmInfo: AIClient.PlaceInfo? {
        guard isActive else { return nil }
        let route = routeShape.routeDescription
        guard let s = snapshot, Date().timeIntervalSince(s.asOf) < 300 else {
            // No fresh place names yet — the route shape alone is still
            // worth sending once it has an opinion.
            return route.map { AIClient.PlaceInfo(road: nil, area: nil, pois: [], route: $0) }
        }
        if s.road == nil && s.area == nil && s.pois.isEmpty && route == nil { return nil }
        return AIClient.PlaceInfo(road: s.road, area: s.area, pois: s.pois, route: route)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.consider(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS hiccups are routine mid-run; the next fix retries.
    }

    // MARK: - Sampling

    private func consider(_ loc: CLLocation) {
        guard isActive else { return }
        // Every fix feeds the route geometry; geocoding/POI below throttles.
        routeShape.add(loc)
        guard !refreshing else { return }
        let movedEnough = lastFix.map { loc.distance(from: $0) > 300 } ?? true
        let waitedEnough = lastFixAt.map { Date().timeIntervalSince($0) > 120 } ?? true
        guard movedEnough || waitedEnough else { return }
        refreshing = true
        lastFix = loc
        lastFixAt = Date()
        Task { @MainActor in
            await self.refresh(at: loc)
            self.refreshing = false
        }
    }

    private func refresh(at loc: CLLocation) async {
        async let placemarkTask = self.reverseGeocode(loc)
        async let poisTask = self.nearbyPOIs(loc)
        let placemark = await placemarkTask
        let pois = await poisTask
        guard isActive else { return }
        let snap = Snapshot(
            road: placemark?.thoroughfare,
            area: placemark?.subLocality ?? placemark?.locality,
            pois: pois,
            asOf: Date()
        )
        snapshot = snap
        let where_ = [snap.road, snap.area].compactMap { $0 }.joined(separator: ", ")
        RunEventLog.shared.record("place.context", where_.isEmpty ? "(unnamed)" : where_,
                                  data: ["pois": pois.joined(separator: " | "),
                                         "route": routeShape.routeDescription ?? ""])
    }

    private func reverseGeocode(_ loc: CLLocation) async -> CLPlacemark? {
        try? await geocoder.reverseGeocodeLocation(loc).first
    }

    private func nearbyPOIs(_ loc: CLLocation) async -> [String] {
        // MapKit's POI space is GCJ-02 inside mainland China; the raw
        // WGS-84 fix must be shifted or results land ~500 m away.
        let center = ChinaCoordinateTransform.displayCoordinate(loc.coordinate)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: 280)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: Self.categories)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        struct Ranked { let label: String; let hotelRank: Int; let meters: Int }
        let ranked: [Ranked] = response.mapItems.compactMap { item in
            guard let name = item.name, let itemLoc = item.placemark.location else { return nil }
            let meters = Int(itemLoc.distance(from: centerLoc))
            let cat = Self.label(item.pointOfInterestCategory)
            return Ranked(
                label: "\(name) (\(cat), \(meters)m)",
                hotelRank: item.pointOfInterestCategory == .hotel ? 0 : 1,
                meters: meters
            )
        }
        return ranked
            .sorted { ($0.hotelRank, $0.meters) < ($1.hotelRank, $1.meters) }
            .prefix(5)
            .map(\.label)
    }

    private static func label(_ category: MKPointOfInterestCategory?) -> String {
        switch category {
        case .some(.hotel): return "hotel"
        case .some(.nightlife): return "bar"
        case .some(.brewery): return "brewery"
        case .some(.winery): return "winery"
        case .some(.restaurant): return "restaurant"
        case .some(.cafe): return "cafe"
        case .some(.bakery): return "bakery"
        case .some(.park): return "park"
        case .some(.fitnessCenter): return "gym"
        case .some(.stadium): return "stadium"
        case .some(.theater): return "theatre"
        case .some(.museum): return "museum"
        default: return "place"
        }
    }
}
