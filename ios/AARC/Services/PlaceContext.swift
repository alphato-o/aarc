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

    /// A named place near the runner, with a map-plottable coordinate.
    /// `coordinate` is already in Apple-Maps display space (GCJ-02 inside
    /// mainland China) — it came straight out of an MKLocalSearch — so it
    /// drops onto a MapKit map with no further transform.
    struct POIPin: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let category: String        // "hotel", "bar", "park", …
        let coordinate: CLLocationCoordinate2D
        let meters: Int
        let isHotel: Bool
        /// SF Symbol for the map marker.
        var symbol: String {
            switch category {
            case "hotel": return "bed.double.fill"
            case "bar", "brewery", "winery": return "wineglass.fill"
            case "restaurant": return "fork.knife"
            case "cafe", "bakery": return "cup.and.saucer.fill"
            case "park": return "tree.fill"
            case "gym": return "figure.run"
            case "stadium": return "sportscourt.fill"
            case "theatre": return "theatermasks.fill"
            case "museum": return "building.columns.fill"
            case "mall": return "bag.fill"
            case "landmark": return "building.2.fill"
            case "attraction": return "star.fill"
            case "government": return "shield.fill"
            default: return "mappin"
            }
        }
    }

    private(set) var snapshot: Snapshot?
    private(set) var isActive = false

    // MARK: - Map state (all in Apple-Maps display space, ready to plot)

    /// One trail vertex with the performance at that point, so the map can
    /// hue the line by pace or heart rate (NRC-style). Coord is display space.
    struct TrailPoint: Sendable {
        let coord: CLLocationCoordinate2D
        let kmh: Double?
        let hr: Double?
    }

    /// Where the runner is right now (display space). nil until first fix.
    private(set) var displayCurrent: CLLocationCoordinate2D?
    /// Last RAW WGS-84 fix — for the server's weather/AQI/news (Open-Meteo is
    /// WGS), and the ambient block. Set on outdoor fixes + the treadmill
    /// one-shot below.
    private(set) var lastWGS: CLLocationCoordinate2D?
    /// Treadmill venue guess + city from a one-shot lookup (indoor runs have
    /// no continuous GPS; this is a single coarse fix, no trail pollution).
    var treadmillVenue: String?
    private var ambientCity: String?
    /// The path travelled so far with per-point metrics (display space).
    private(set) var trail: [TrailPoint] = []
    /// Just the coordinates — kept for callers that only need the line.
    var displayTrail: [CLLocationCoordinate2D] { trail.map(\.coord) }
    /// Most recent nearby POIs as map pins (hotels first).
    private(set) var poiPins: [POIPin] = []
    /// Metres since the last `gps` event was logged (web-map trail).
    private var lastGpsLogAt: CLLocation?
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

    /// "Worth mentioning" search terms — only landmark-grade places, not
    /// every cafe. MapKit exposes no prominence score, so we query a curated
    /// set of high-signal terms (in zh for China so names come back local)
    /// and then prune by name. Hotels are filtered hard to the prestige tier
    /// (no hostels / budget chains — the runner isn't fantasising about a
    /// Youth Hostel). category drives the marker; isHotel keeps hotels first.
    private struct POITerm { let term: String; let category: String; let isHotel: Bool }
    private static let poiTerms: [POITerm] = [
        // prestige hotels (brand names pull the real ones to the top)
        POITerm(term: "豪华酒店", category: "hotel", isHotel: true),
        POITerm(term: "五星级酒店", category: "hotel", isHotel: true),
        POITerm(term: "luxury hotel", category: "hotel", isHotel: true),
        // landmarks / prominent buildings
        POITerm(term: "地标", category: "landmark", isHotel: false),
        POITerm(term: "landmark", category: "landmark", isHotel: false),
        POITerm(term: "tower", category: "landmark", isHotel: false),
        // malls
        POITerm(term: "购物中心", category: "mall", isHotel: false),
        POITerm(term: "shopping mall", category: "mall", isHotel: false),
        // parks + attractions
        POITerm(term: "公园", category: "park", isHotel: false),
        POITerm(term: "景点", category: "attraction", isHotel: false),
        POITerm(term: "park", category: "park", isHotel: false),
        // civic / culture
        POITerm(term: "博物馆", category: "museum", isHotel: false),
        POITerm(term: "体育场", category: "stadium", isHotel: false),
        POITerm(term: "政府", category: "government", isHotel: false),
    ]
    /// Hotel name tokens that mean "prestige" — keep these.
    private static let hotelKeepTokens = [
        "shangri", "ritz", "four seasons", "四季", "st. regis", "瑞吉", "mandarin", "文华",
        "park hyatt", "柏悦", "grand hyatt", "凯悦", "waldorf", "华尔道夫", "rosewood", "瑞吉",
        "peninsula", "半岛", "kerry", "嘉里", "jw marriott", "万豪", "intercontinental", "洲际",
        "hilton", "希尔顿", "kempinski", "凯宾斯基", "westin", "威斯汀", "sheraton", "喜来登",
        "fairmont", "费尔蒙", "conrad", "康莱德", "edition", "raffles", "莱佛士", "sofitel", "索菲特",
        "豪华", "国际", "大酒店", "grand hotel", "regent", "丽晶",
    ]
    /// Anything containing these is NOT worth a mention — drop it.
    private static let dropTokens = [
        "hostel", "旅舍", "招待所", "青年", "宾馆", "快捷", "express", "inn", "motel", "budget",
        "如家", "汉庭", "7天", "锦江之星", "公寓", "民宿", "客栈",
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
        displayCurrent = nil; trail = []; poiPins = []; lastGpsLogAt = nil
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
        displayCurrent = nil; trail = []; poiPins = []; lastGpsLogAt = nil
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
    /// Raw real-time signals for the server to enrich. Time is always
    /// present; location/city come from live GPS (outdoor) or the treadmill
    /// one-shot; venue is treadmill-only.
    var ambientInfo: AIClient.AmbientInfo {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"; let clock = f.string(from: now)
        f.dateFormat = "EEEE"; let wd = f.string(from: now)
        f.dateFormat = "d MMMM"; let md = f.string(from: now)
        return AIClient.AmbientInfo(
            lat: lastWGS?.latitude, lon: lastWGS?.longitude,
            city: snapshot?.area ?? ambientCity,
            venue: treadmillVenue,
            localClock: clock, weekday: wd, monthDay: md)
    }

    /// Seed location/city/venue from the treadmill one-shot (no continuous
    /// tracking indoors → no trail, no gps logging).
    func setTreadmillContext(coord: CLLocationCoordinate2D, city: String?, venue: String?) {
        lastWGS = coord
        ambientCity = city
        treadmillVenue = venue
    }

    var llmInfo: AIClient.PlaceInfo? {
        guard isActive else { return nil }
        let route = routeShape.routeDescription
        guard let s = snapshot, Date().timeIntervalSince(s.asOf) < 300 else {
            // No fresh place names yet — the route shape alone is still
            // worth sending once it has an opinion.
            return route.map { AIClient.PlaceInfo(road: nil, area: nil, pois: [], route: $0) }
        }
        if s.road == nil && s.area == nil && s.pois.isEmpty && route == nil { return nil }
        // Clamp hard so an over-long field can never 400 the LLM request
        // (the avalanche that silently killed Jessica). pois are already
        // name-only; cap count + length defensively.
        return AIClient.PlaceInfo(
            road: s.road.map { String($0.prefix(100)) },
            area: s.area.map { String($0.prefix(100)) },
            pois: Array(s.pois.prefix(6)).map { String($0.prefix(60)) },
            route: route.map { String($0.prefix(180)) })
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
        lastWGS = loc.coordinate
        // Map state: current position + metric-tagged trail, in display space.
        let disp = ChinaCoordinateTransform.displayCoordinate(loc.coordinate)
        displayCurrent = disp
        let m = LiveMetricsConsumer.shared.latest
        let kmh: Double? = m?.currentPaceSecPerKm.map { $0 > 0 ? 3600 / $0 : 0 }
        let pt = TrailPoint(coord: disp, kmh: kmh, hr: m?.currentHeartRate)
        if let last = trail.last?.coord {
            let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: disp.latitude, longitude: disp.longitude))
            if d > 8 { trail.append(pt) }
        } else {
            trail.append(pt)
        }
        if trail.count > 1200 { trail.removeFirst(trail.count - 1200) }
        // Log the raw WGS-84 fix every ~20m for the web dashboard map, which
        // renders on WGS-84 OSM tiles (NOT GCJ — that's the iOS-map datum).
        let logged = lastGpsLogAt.map { loc.distance(from: $0) > 20 } ?? true
        if logged {
            lastGpsLogAt = loc
            RunEventLog.shared.record("gps", "",
                data: ["lat": String(format: "%.6f", loc.coordinate.latitude),
                       "lon": String(format: "%.6f", loc.coordinate.longitude),
                       "kmh": kmh.map { String(format: "%.1f", $0) } ?? "",
                       "hr": m?.currentHeartRate.map { String(Int($0)) } ?? ""])
        }
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
        async let pinsTask = self.nearbyPOIs(loc)
        let placemark = await placemarkTask
        let pins = await pinsTask
        guard isActive else { return }
        poiPins = pins
        // NAME ONLY for the coaches — a local says "the Shangri-La", not
        // "Shangri-La (hotel, 140m)". Clamp each for the proxy's per-entry cap.
        let labels = pins.map { String($0.name.prefix(60)) }
        let snap = Snapshot(
            road: placemark?.thoroughfare,
            area: placemark?.subLocality ?? placemark?.locality,
            pois: labels,
            asOf: Date()
        )
        snapshot = snap
        let where_ = [snap.road, snap.area].compactMap { $0 }.joined(separator: ", ")
        // POI coords for the WEB map (MapLibre on WGS-84 OSM tiles) — the pin
        // coords from MapKit are GCJ-02, so invert them back to WGS-84 here.
        // Format: "name|wgsLat|wgsLon|hotel" per pin, semicolon-joined.
        let poic = pins.prefix(6).map { p -> String in
            let w = ChinaCoordinateTransform.wgsCoordinate(fromDisplay: p.coordinate)
            return "\(p.name.replacingOccurrences(of: "|", with: " "))|\(String(format: "%.6f", w.latitude))|\(String(format: "%.6f", w.longitude))|\(p.isHotel ? 1 : 0)"
        }.joined(separator: ";")
        RunEventLog.shared.record("place.context", where_.isEmpty ? "(unnamed)" : where_,
                                  data: ["pois": labels.joined(separator: " | "),
                                         "poic": poic,
                                         "route": routeShape.routeDescription ?? ""])
    }

    private func reverseGeocode(_ loc: CLLocation) async -> CLPlacemark? {
        // Force the LOCAL script in mainland China (zh-Hans) so the names
        // are the real ones the runner sees on signs — and so 11Labs reads
        // 东大桥路 natively instead of mangling "Dongdaqiao Road".
        let inChina = ChinaCoordinateTransform.isMainlandChina(loc.coordinate)
        let locale = inChina ? Locale(identifier: "zh_Hans_CN") : nil
        return try? await geocoder.reverseGeocodeLocation(loc, preferredLocale: locale).first
    }

    private func nearbyPOIs(_ loc: CLLocation) async -> [POIPin] {
        // MapKit's POI space is GCJ-02 inside mainland China; shift the
        // search centre or results land ~500 m off. Returned coordinates
        // are in that same display space, so pins plot directly on the map.
        let center = ChinaCoordinateTransform.displayCoordinate(loc.coordinate)
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        // Wider radius for landmark-grade places (you'd mention a tower 700m
        // away; not a cafe 700m away).
        let region = MKCoordinateRegion(center: center,
                                        latitudinalMeters: 1400, longitudinalMeters: 1400)
        let groups = await withTaskGroup(of: [POIPin].self) { group -> [POIPin] in
            for t in Self.poiTerms {
                group.addTask { await Self.search(term: t, region: region, center: centerLoc) }
            }
            var all: [POIPin] = []
            for await pins in group { all.append(contentsOf: pins) }
            return all
        }
        // Dedupe by name, keep nearest; prune to prominent only; hotels first.
        var byName: [String: POIPin] = [:]
        for p in groups {
            if !Self.isProminent(p) { continue }
            if let e = byName[p.name], e.meters <= p.meters { continue }
            byName[p.name] = p
        }
        let top = byName.values
            .sorted { ($0.isHotel ? 0 : 1, $0.meters) < ($1.isHotel ? 0 : 1, $1.meters) }
            .prefix(6).map { $0 }
        // Localize NON-hotel names to the local script (parks/landmarks
        // transliterate badly; hotels keep their English brand — "Park Hyatt"
        // reads fine). Best-effort reverse-geocode in zh; keep English if no
        // local name surfaces.
        guard ChinaCoordinateTransform.isMainlandChina(loc.coordinate) else { return top }
        var out: [POIPin] = []
        for p in top {
            if p.isHotel { out.append(p); continue }
            out.append(await localizedPOI(p))
        }
        return out
    }

    /// Reverse-geocode a POI's point in zh and adopt the local-script name if
    /// one surfaces (areasOfInterest names the park/landmark). The pin coord is
    /// display-space (GCJ); invert to WGS-84 for the geocoder.
    private func localizedPOI(_ pin: POIPin) async -> POIPin {
        let wgs = ChinaCoordinateTransform.wgsCoordinate(fromDisplay: pin.coordinate)
        let loc = CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)
        guard let pm = try? await CLGeocoder().reverseGeocodeLocation(
            loc, preferredLocale: Locale(identifier: "zh_Hans_CN")).first else { return pin }
        let candidate = pm.areasOfInterest?.first ?? pm.name
        if let name = candidate,
           name.range(of: "\\p{Han}", options: .regularExpression) != nil {
            return POIPin(name: name, category: pin.category, coordinate: pin.coordinate,
                          meters: pin.meters, isHotel: false)
        }
        return pin
    }

    /// Keep only places worth a coach line: hotels must be prestige-tier;
    /// everything within a category-appropriate radius; nothing on the
    /// budget/hostel droplist.
    private static func isProminent(_ p: POIPin) -> Bool {
        let n = p.name.lowercased()
        for d in dropTokens where n.contains(d) { return false }
        if p.isHotel {
            // Hotels: must read prestige AND be reasonably close.
            guard p.meters <= 600 else { return false }
            return hotelKeepTokens.contains { n.contains($0) }
        }
        // Landmarks/malls/parks/etc: a generous radius, name must be real.
        let radius = (p.category == "park" || p.category == "landmark") ? 900 : 600
        return p.meters <= radius && p.name.count >= 2
    }

    private static func search(term: POITerm, region: MKCoordinateRegion, center: CLLocation) async -> [POIPin] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = term.term
        req.region = region
        req.resultTypes = .pointOfInterest
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.compactMap { item in
            guard let raw = item.name, let l = item.placemark.location else { return nil }
            return POIPin(name: shortenName(raw), category: term.category,
                          coordinate: l.coordinate, meters: Int(l.distance(from: center)),
                          isHotel: term.isHotel)
        }
    }

    /// How a local would say it: trim generic suffixes / parenthetical
    /// branch+address noise so the coach says "Shangri-La", not
    /// "Shangri-La Hotel (Pudong Riverside Wing, 33 Fucheng Rd)".
    private static func shortenName(_ raw: String) -> String {
        var s = raw
        if let paren = s.firstIndex(where: { $0 == "(" || $0 == "（" }) { s = String(s[..<paren]) }
        if let dash = s.range(of: " - ") { s = String(s[..<dash.lowerBound]) }
        s = s.trimmingCharacters(in: .whitespaces)
        for suffix in ["大酒店", "酒店", " Hotel", " Hotels", " Resort"] {
            if s.hasSuffix(suffix), s.count > suffix.count + 1 { s = String(s.dropLast(suffix.count)) }
        }
        return s.trimmingCharacters(in: .whitespaces)
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
