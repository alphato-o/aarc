import Foundation
import Observation
import CoreLocation
import MapKit
import AARCKit

/// A synthetic GPS route the desk simulator walks along, so a simulated
/// OUTDOOR run exercises the real place-awareness pipeline (geocoding,
/// POI lookups, route-shape detection) from the founder's chair.
///
/// Built from the device's actual location: a random bearing is picked,
/// MKDirections plots a real walking route out to ~45% of the planned
/// distance, and the return leg retraces it — a plausible out-and-back
/// past real roads and real POIs. If directions fail (offline, no route),
/// a geometric dogleg stands in; names still resolve, geometry still loops.
struct SimRoute {
    let coords: [CLLocationCoordinate2D]   // WGS-84
    let cum: [Double]                      // cumulative meters per vertex
    let total: Double

    /// Position after `dist` simulated meters; wraps so an open run keeps
    /// repeating the circuit (and the lap detector gets material).
    func location(at dist: Double) -> CLLocation {
        guard total > 0, coords.count > 1 else {
            return CLLocation(latitude: coords.first?.latitude ?? 0,
                              longitude: coords.first?.longitude ?? 0)
        }
        var d = dist.truncatingRemainder(dividingBy: total)
        if d < 0 { d += total }
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= d { lo = mid } else { hi = mid }
        }
        let span = cum[hi] - cum[lo]
        let f = span > 0 ? (d - cum[lo]) / span : 0
        let a = coords[lo], b = coords[hi]
        return CLLocation(
            latitude: a.latitude + (b.latitude - a.latitude) * f,
            longitude: a.longitude + (b.longitude - a.longitude) * f
        )
    }

    static func build(points: [CLLocationCoordinate2D]) -> SimRoute? {
        guard points.count > 1 else { return nil }
        var cum: [Double] = [0]
        var total: Double = 0
        for i in 1..<points.count {
            let a = CLLocation(latitude: points[i-1].latitude, longitude: points[i-1].longitude)
            let b = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            total += b.distance(from: a)
            cum.append(total)
        }
        guard total > 50 else { return nil }
        return SimRoute(coords: points, cum: cum, total: total)
    }
}

enum SimRouteBuilder {
    /// Offset a WGS-84 coordinate by `meters` along `bearing` (radians).
    static func offset(_ c: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let dLat = meters * cos(bearing) / 111_320.0
        let dLon = meters * sin(bearing) / (111_320.0 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    /// Out-and-back route from `origin`, total length ≈ `targetMeters`.
    static func build(from origin: CLLocationCoordinate2D, targetMeters: Double) async -> SimRoute? {
        let bearing = Double.random(in: 0..<(2 * .pi))
        let outMeters = max(300, targetMeters * 0.45)
        let target = offset(origin, bearing: bearing, meters: outMeters)

        // MKDirections speaks Apple-Maps space — GCJ-02 inside mainland
        // China — so shift the request in and the polyline back out.
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(
            coordinate: ChinaCoordinateTransform.displayCoordinate(origin)))
        req.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: ChinaCoordinateTransform.displayCoordinate(target)))
        req.transportType = .walking

        if let route = try? await MKDirections(request: req).calculate().routes.first {
            let poly = route.polyline
            var pts = [CLLocationCoordinate2D](
                repeating: CLLocationCoordinate2D(), count: poly.pointCount)
            poly.getCoordinates(&pts, range: NSRange(location: 0, length: poly.pointCount))
            let wgs = pts.map(ChinaCoordinateTransform.wgsCoordinate(fromDisplay:))
            if let r = SimRoute.build(points: wgs + wgs.dropLast().reversed()) {
                return r
            }
        }
        // Fallback: geometric dogleg out-and-back. Roads aren't followed,
        // but reverse geocoding + POI search still resolve real names.
        let mid = offset(origin, bearing: bearing + 0.5, meters: outMeters * 0.5)
        let out = [origin, mid, target]
        return SimRoute.build(points: out + out.dropLast().reversed())
    }
}

/// Desk-test metrics source. When the start screen's test mode is
/// `.simulate`, this drives SYNTHETIC `LiveMetrics` into the exact same
/// pipeline a real run uses (`LiveMetricsConsumer.ingest`) — so the
/// director, ContextualCoach, Jessica producer, ScriptEngine milestones and
/// all the audio fire just as they would on the road, without the founder
/// leaving his chair. No GPS, no pedometer, no HealthKit.
///
/// The Control Room exposes live controls (pace, speed multiplier,
/// pause/stationary, HR/pace event injects, distance jump) so a whole run
/// can be exercised — including fast-forwarding to the painful back half to
/// hear how Jessica ramps.
@MainActor
@Observable
final class RunSimulator {
    static let shared = RunSimulator()

    private(set) var isActive = false

    // MARK: - Operator controls (read + written by the Control Room)

    /// Target pace. Distance accrues at 1000/pace m/s (× the multiplier).
    var paceSecPerKm: Double = 360          // 6:00 /km
    /// 1× = real time. Higher accelerates BOTH distance and the run clock so
    /// you reach milestones / the late-run Jessica ramp sooner. Audio still
    /// plays in real time (you can't speed up a voice line meaningfully).
    var speedMultiplier: Double = 1.0
    /// Paused = the clock and distance freeze (you're "standing still" — good
    /// for triggering the stationary roast).
    var paused = false

    // Synthetic HR model.
    var targetHeartRate: Double = 150

    /// Autonomous realism: deliberate pace wander, cardiac drift, and
    /// street-life events (crossings pause you, alleys slow you, open
    /// stretches let you surge) so the trail/HR vary like a real run and
    /// the place pipeline + colored map get a proper workout. The operator
    /// controls still set the baseline; this rides on top.
    var autoVary = true
    private var paceWander: Double = 0
    private var autoEventUntil: TimeInterval = 0
    private var nextEventAt: TimeInterval = 30
    private enum AutoEvent { case none, crossing, alley, surge }
    private var autoEvent: AutoEvent = .none
    /// Human-readable current event for the Control Room.
    private(set) var autoEventLabel: String = ""

    // MARK: - Synthetic state

    private(set) var simElapsed: TimeInterval = 0
    private(set) var simDistance: Double = 0
    private var smoothedHR: Double = 110
    private var hrSpikeUntil: TimeInterval = 0
    private var surgeUntil: TimeInterval = 0
    private var stationaryUntil: TimeInterval = 0
    private var lastWall: Date?
    private var ticker: Timer?

    /// Synthetic GPS for simulated OUTDOOR runs — drives PlaceContext so
    /// location-grounded feedback can be desk-verified. nil while the
    /// route is still being plotted (or for treadmill sims).
    private(set) var simRoute: SimRoute?
    /// Where the route started — surfaces in the Control Room panel.
    private(set) var routeStatus: String = ""

    /// The planned synthetic route in Apple-Maps display space, for the
    /// map overlay. Empty until the route is plotted (or for treadmill).
    var displayRouteCoords: [CLLocationCoordinate2D] {
        guard let r = simRoute else { return [] }
        return r.coords.map(ChinaCoordinateTransform.displayCoordinate)
    }

    private init() {}

    // MARK: - Lifecycle

    func start(runType: RunType, runId: UUID, personalityId: String, plan: RunPlan) {
        simElapsed = 0
        simDistance = 0
        smoothedHR = 110
        hrSpikeUntil = 0; surgeUntil = 0; stationaryUntil = 0
        paused = false
        lastWall = nil
        isActive = true
        simRoute = nil
        routeStatus = ""
        paceWander = 0; autoEvent = .none; autoEventLabel = ""
        autoEventUntil = 0; nextEventAt = 30

        LiveMetricsConsumer.shared.pendingRunType = runType
        LiveMetricsConsumer.shared.pendingPersonalityId = personalityId
        LiveMetricsConsumer.shared.ingestStarted(runId: runId, startedAt: Date())

        // Mirror the desk sim to the watch (display-only) so its UI/UX can be
        // checked without a real run.
        PhoneSession.shared.sendStateEvent(.simStart(runId: runId, runType: runType))

        // Simulated OUTDOOR run: plot a synthetic route from the device's
        // real location so the place-awareness pipeline fires for real.
        if runType == .outdoor {
            routeStatus = "plotting route\u{2026}"
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Last cached fix is fine — we're at a desk, not moving.
                let origin = CLLocationManager().location?.coordinate
                    ?? CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
                let target: Double
                switch plan.kind {
                case .distance: target = max((plan.distanceKm ?? 3) * 1000, 600)
                case .time:
                    let mins = plan.timeMinutes ?? 30
                    target = max(mins * 60 / max(self.paceSecPerKm, 60) * 1000, 600)
                case .open: target = Double.random(in: 1800...4200)
                }
                let route = await SimRouteBuilder.build(from: origin, targetMeters: target)
                guard self.isActive else { return }
                self.simRoute = route
                self.routeStatus = route.map {
                    "route: \(Int($0.total))m out-and-back"
                } ?? "route plotting failed — metrics only"
            }
        }

        ticker?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker = t
    }

    func end() {
        guard isActive else { return }
        isActive = false
        ticker?.invalidate(); ticker = nil
        lastWall = nil
        PhoneSession.shared.sendStateEvent(.simEnd)
        LiveMetricsConsumer.shared.ingestEnded(workoutUUID: nil)
    }

    // MARK: - Operator actions

    func injectHRSpike() { hrSpikeUntil = simElapsed + 25 }
    func injectPaceSurge() { surgeUntil = simElapsed + 20 }
    func injectStationary() { stationaryUntil = simElapsed + 30 }

    /// Fast-forward the run by `meters`, advancing the clock at the current
    /// pace too, so scrubbing to "5 km" lands you at the right time as well.
    func jump(meters: Double) {
        guard isActive, meters > 0 else { return }
        simDistance += meters
        let speed = 1000.0 / max(60, paceSecPerKm)
        simElapsed += meters / speed
        publish()
    }

    // MARK: - Tick

    private func tick() {
        guard isActive else { return }
        let now = Date()
        let dtReal = lastWall.map { now.timeIntervalSince($0) } ?? 1.0
        lastWall = now
        guard !paused else { publish(); return }

        let dt = dtReal * max(0.25, speedMultiplier)
        simElapsed += dt
        updateAutoEvents()

        // Standing still: a manual inject OR an autonomous street crossing.
        let stationary = simElapsed < stationaryUntil || autoEvent == .crossing
        // Effective pace = baseline × event factor × wander. Surge (manual or
        // auto) speeds up (lower sec/km); alley slows down.
        var factor = 1.0
        if simElapsed < surgeUntil || autoEvent == .surge { factor *= 0.80 }
        if autoEvent == .alley { factor *= 1.28 }
        factor *= (1 + paceWander)
        let pace = max(120, paceSecPerKm * factor)
        if !stationary {
            simDistance += (1000.0 / pace) * dt
        }

        // HR: cardiac drift upward over the run (+~0.4 bpm/min), a floor when
        // stationary, a bump on a spike or when pushing the pace.
        let drift = min(18, simElapsed / 60 * 0.4)
        var hrTarget = targetHeartRate + drift
        if stationary { hrTarget = 95 + drift * 0.5 }
        else if simElapsed < hrSpikeUntil { hrTarget += 35 }
        else if factor < 0.9 { hrTarget += 10 }      // working the surge
        else if autoEvent == .alley { hrTarget -= 6 } // easing through the alley
        smoothedHR += (hrTarget - smoothedHR) * min(1, dt / 12)

        publish(stationaryNow: stationary, curPace: stationary ? nil : pace)
    }

    /// Schedule + advance autonomous street-life events.
    private func updateAutoEvents() {
        guard autoVary else { autoEvent = .none; autoEventLabel = ""; return }
        // Gentle random-walk on pace (±~15%), mean-reverting.
        paceWander += Double.random(in: -0.04...0.04) - paceWander * 0.08
        paceWander = max(-0.16, min(0.16, paceWander))
        if simElapsed >= autoEventUntil {
            if autoEvent != .none {
                autoEvent = .none; autoEventLabel = ""
                nextEventAt = simElapsed + Double.random(in: 45...110)
            } else if simElapsed >= nextEventAt {
                let r = Double.random(in: 0..<1)
                if r < 0.42 {
                    autoEvent = .crossing; autoEventLabel = "waiting to cross"
                    autoEventUntil = simElapsed + Double.random(in: 5...14)
                } else if r < 0.7 {
                    autoEvent = .alley; autoEventLabel = "narrow alley — easing"
                    autoEventUntil = simElapsed + Double.random(in: 20...45)
                } else {
                    autoEvent = .surge; autoEventLabel = "open stretch — pushing"
                    autoEventUntil = simElapsed + Double.random(in: 15...30)
                }
            }
        }
    }

    private func publish(stationaryNow: Bool = false, curPace: Double? = nil, surging: Bool = false) {
        let publishedPace: Double? = stationaryNow ? nil : (curPace ?? paceSecPerKm)
        let avg = simDistance > 0 ? simElapsed / (simDistance / 1000) : 0
        let metrics = LiveMetrics(
            elapsed: simElapsed,
            distanceMeters: simDistance,
            currentPaceSecPerKm: publishedPace,
            avgPaceSecPerKm: avg,
            currentHeartRate: smoothedHR,
            energyKcal: simDistance * 0.06,
            cadenceStepsPerMinute: stationaryNow ? 0 : (160 + (surging ? 14 : 0)),
            lastSplit: nil,
            state: .running
        )
        LiveMetricsConsumer.shared.ingest(metrics)
        // Mirror metrics to the watch sim display.
        PhoneSession.shared.sendBestEffort(.liveMetrics(metrics))

        // Walk the synthetic route — PlaceContext gets a fix per tick and
        // applies its own thresholds, exactly as with real GPS.
        if let route = simRoute {
            PlaceContext.shared.ingestSimulated(route.location(at: simDistance))
            // Mirror the trail to the watch sim map (downsampled, display space).
            let trail = PlaceContext.shared.trail
            if !trail.isEmpty {
                let step = max(1, trail.count / 120)
                let sampled = stride(from: 0, to: trail.count, by: step).map { trail[$0] }
                PhoneSession.shared.sendBestEffort(.simTrail(
                    lats: sampled.map { $0.coord.latitude },
                    lons: sampled.map { $0.coord.longitude },
                    kmh: sampled.map { $0.kmh },
                    hr: sampled.map { $0.hr }))
            }
        }
    }
}
