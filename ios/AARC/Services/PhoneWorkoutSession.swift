import Foundation
import CoreLocation
import CoreMotion
import HealthKit
import Observation
import OSLog
import AARCKit

/// Phone-side workout tracker. Mirrors the role `WorkoutSessionHost`
/// plays on the watch, but uses CoreLocation for distance / pace and
/// writes the workout to HealthKit via `HKWorkoutBuilder` on the
/// iPhone. Enables a true phone-only run mode — same flow NRC,
/// Strava, Apple Fitness use when there's no Apple Watch attached.
///
/// Downstream pipeline (ScriptEngine, ContextualCoach, LiveActivity,
/// audio coaching) is identical to the watch path because we publish
/// the same `LiveMetrics` shape via `LiveMetricsConsumer.ingest`. No
/// changes needed in those layers.
///
/// MVP scope:
///   - outdoor: GPS distance / pace from CLLocationManager
///   - treadmill: step-derived distance / pace / cadence from
///     CMPedometer (estimated stride length × steps). Less accurate
///     than a Stryd pod but unblocks the "stranded at the gym with
///     no working watch" scenario.
///   - no heart rate (phone has no HR sensor; live HR from a wrist-
///     worn watch can be wired in later)
@Observable
@MainActor
final class PhoneWorkoutSession: NSObject {
    static let shared = PhoneWorkoutSession()

    // MARK: - Observable state (read by SettingsView / RunHomeView)

    private(set) var isActive: Bool = false
    private(set) var currentRunId: UUID?
    private(set) var startedAt: Date?
    private(set) var lastError: String?

    // MARK: - Tracking state

    private let healthStore = HKHealthStore()
    private var workoutBuilder: HKWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var locationManager: CLLocationManager?
    private var pedometer: CMPedometer?

    /// Accumulated distance in meters.
    private var distanceMeters: Double = 0
    /// Latest cadence from the pedometer in steps-per-minute. nil when
    /// outdoor (we don't run the pedometer there) or when CMPedometer
    /// hasn't produced a cadence reading yet.
    private var currentCadenceSPM: Double?

    // Read-only mirrors for the in-app diagnostics panel. Not part of
    // the normal API surface; intentionally lowercase suffix to avoid
    // accidental use from other call sites.
    var distanceMetersForDiagnostics: Double { distanceMeters }
    var currentCadenceSPMForDiagnostics: Double? { currentCadenceSPM }
    /// Last accepted location (used to compute the next delta).
    private var lastLocation: CLLocation?
    /// Sliding window of recent (timestamp, distance-meters) pairs for
    /// computing the instantaneous pace over the last ~10s.
    private var paceWindow: [(t: Date, d: Double)] = []
    private let paceWindowSeconds: TimeInterval = 10

    /// 1Hz publisher driving LiveMetricsConsumer.
    private var publishTimer: Timer?

    /// Buffered route locations awaiting flush to the route builder.
    private var pendingRouteLocations: [CLLocation] = []

    private let log = Logger(subsystem: "club.aarun.AARC", category: "PhoneWorkout")

    // MARK: - Public API

    /// Begin a phone-tracked run. Returns immediately; the workout
    /// runs until `end()` is called.
    func start(runType: RunType, runId: UUID, personalityId: String) async throws {
        log.info("[start] runType=\(runType.rawValue, privacy: .public) runId=\(runId.uuidString.prefix(8), privacy: .public)")
        guard !isActive else {
            log.info("[start] already active — ignoring")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            log.error("[start] HK unavailable, throwing")
            throw PhoneWorkoutError.healthKitUnavailable
        }
        // Treadmill / indoor doesn't need GPS — only pedometer. We
        // still want location auth for outdoor; for treadmill we skip
        // the check entirely so a runner who never granted location
        // can still hit the gym.
        if runType == .outdoor {
            let auth = CLLocationManager().authorizationStatus
            guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
                throw PhoneWorkoutError.locationNotAuthorized
            }
        } else {
            // Treadmill: hard-fail on denied Motion permission so the
            // runner sees an actionable error in RunHome instead of a
            // chart that sits at zero forever. Step counting in the
            // foreground theoretically works without permission, but
            // distance + cadence absolutely require it, and the run
            // would be useless without distance.
            log.info("[start] treadmill auth check: stepCountingAvailable=\(CMPedometer.isStepCountingAvailable(), privacy: .public) authStatus=\(CMPedometer.authorizationStatus().rawValue, privacy: .public)")
            guard CMPedometer.isStepCountingAvailable() else {
                log.error("[start] stepCounting unavailable, throwing motionNotAuthorized")
                throw PhoneWorkoutError.motionNotAuthorized
            }
            let motionAuth = CMPedometer.authorizationStatus()
            if motionAuth == .denied || motionAuth == .restricted {
                log.error("[start] motion denied/restricted (\(motionAuth.rawValue, privacy: .public)), throwing")
                throw PhoneWorkoutError.motionNotAuthorized
            }
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = (runType == .treadmill) ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: config,
            device: .local()
        )
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())

        let now = Date()
        try await builder.beginCollection(at: now)
        self.workoutBuilder = builder
        self.routeBuilder = routeBuilder

        // Reset tracking accumulators.
        self.distanceMeters = 0
        self.lastLocation = nil
        self.paceWindow.removeAll()
        self.pendingRouteLocations.removeAll()
        self.currentCadenceSPM = nil
        self.startedAt = now
        self.currentRunId = runId
        self.lastError = nil

        // Treadmill: pedometer drives distance. Outdoor: GPS drives
        // distance + route. We don't run both simultaneously — they'd
        // double-count steps and burn battery for no gain.
        if runType == .treadmill {
            log.info("[start] entering treadmill branch — pedometer + keepalive")
            startPedometerUpdates(from: now)
            // Phone-only treadmill has no UIBackgroundMode that keeps
            // the app alive when the screen sleeps or the runner
            // briefly backgrounds AARC (outdoor gets .location;
            // treadmill has nothing). The sustained-audio-session
            // approach we tried earlier didn't grant .audio background
            // grace because iOS only counts the mode while audio is
            // actively flowing — not just "session is active". The
            // keepalive plays a silent PCM loop through a dedicated
            // engine so we satisfy that requirement without producing
            // audible output, and without permanently ducking music
            // (no .duckOthers on the keepalive's output).
            AudioPlaybackManager.shared.beginSustained()
            BackgroundAudioKeepalive.shared.start()
        } else {
            log.info("[start] entering outdoor branch — GPS location updates")
            startLocationUpdates(indoor: false)
        }
        startPublishTimer()

        self.isActive = true
        log.info("[start] isActive=true, publishTimer scheduled")

        // Hand the run identity to the existing consumer so ScriptEngine,
        // ContextualCoach and LiveActivity all start their lifecycles the
        // same way they would for a watch-tracked run.
        LiveMetricsConsumer.shared.pendingRunType = runType
        LiveMetricsConsumer.shared.pendingPersonalityId = personalityId
        LiveMetricsConsumer.shared.ingestStarted(runId: runId, startedAt: now)
        log.info("PhoneWorkoutSession started runId=\(runId.uuidString.prefix(8), privacy: .public) type=\(runType.rawValue, privacy: .public)")
    }

    func pause() {
        guard isActive else { return }
        publishTimer?.invalidate()
        publishTimer = nil
        locationManager?.stopUpdatingLocation()
        pedometer?.stopUpdates()
        LiveMetricsConsumer.shared.ingestPaused()
    }

    func resume() {
        guard isActive else { return }
        // Resume only whichever source was actually in use. Starting
        // the wrong one would either burn GPS for nothing on a
        // treadmill OR double-count steps on an outdoor run.
        if pedometer != nil, let startedAt {
            startPedometerUpdates(from: startedAt)
        } else {
            locationManager?.startUpdatingLocation()
        }
        startPublishTimer()
        LiveMetricsConsumer.shared.ingestResumed()
    }

    /// Finish the workout. Returns the HK workout UUID that the
    /// existing persistence pipeline will turn into a RunRecord.
    @discardableResult
    func end() async -> UUID? {
        guard isActive else { return nil }
        let endDate = Date()

        // Stop the live publisher first so we don't fight HK's finalise.
        publishTimer?.invalidate()
        publishTimer = nil
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        pedometer?.stopUpdates()
        pedometer = nil
        // Release the sustained audio session + silent keepalive if
        // they were on (treadmill). No-ops for outdoor runs that
        // never entered sustained mode.
        BackgroundAudioKeepalive.shared.stop()
        AudioPlaybackManager.shared.endSustained()

        // Drain any buffered route locations before HK seals the route.
        let route = pendingRouteLocations
        pendingRouteLocations.removeAll()
        if !route.isEmpty {
            try? await routeBuilder?.insertRouteData(route)
        }

        // Append the final distance + duration samples so Apple Fitness
        // shows the same numbers Live Activity was showing.
        if let builder = workoutBuilder, distanceMeters > 0 {
            let distSample = HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
                start: startedAt ?? endDate,
                end: endDate
            )
            try? await builder.addSamples([distSample])
        }

        // TEST RUN: never write to Apple Health. We collected real GPS/pace
        // (so the live run + diagnostics worked), but we DON'T finishWorkout,
        // so no junk 0.01km entry lands in Fitness. The builder is just
        // dropped; HealthKit only persists on finishWorkout().
        if RunOrchestrator.shared.isTestRun {
            workoutBuilder = nil
            routeBuilder = nil
            isActive = false
            log.info("PhoneWorkoutSession ended TEST run — discarded (no Apple Health write)")
            LiveMetricsConsumer.shared.ingestEnded(workoutUUID: nil)
            currentRunId = nil
            startedAt = nil
            return nil
        }

        var workoutUUID: UUID?
        do {
            try await workoutBuilder?.endCollection(at: endDate)
            // Tag with our run id so the iPhone-side persistence pipeline
            // can link the HK workout back to the original AARC runId.
            if let runId = currentRunId {
                try? await workoutBuilder?.addMetadata([
                    HKMetadataKeys.runId: runId.uuidString
                ])
            }
            if let finished = try await workoutBuilder?.finishWorkout() {
                workoutUUID = finished.uuid
                if !route.isEmpty {
                    _ = try? await routeBuilder?.finishRoute(with: finished, metadata: nil)
                }
                log.info("PhoneWorkoutSession ended; HK workout \(finished.uuid.uuidString.prefix(8), privacy: .public)")
            }
        } catch {
            lastError = error.localizedDescription
            log.error("PhoneWorkoutSession finish failed: \(error.localizedDescription, privacy: .public)")
        }

        workoutBuilder = nil
        routeBuilder = nil
        isActive = false

        if let workoutUUID {
            LiveMetricsConsumer.shared.ingestEnded(workoutUUID: workoutUUID)
        } else {
            // No HK workout was produced (auth gap or finish failed).
            // Still wind down ScriptEngine / ContextualCoach / LiveActivity
            // so we don't leave them orphaned.
            LiveMetricsConsumer.shared.ingestEnded(workoutUUID: UUID())
        }

        currentRunId = nil
        startedAt = nil
        return workoutUUID
    }

    // MARK: - Pedometer (treadmill)

    /// Default running stride length in metres. Used to estimate
    /// distance from raw step count when `CMPedometer.distance`
    /// returns nil — which happens more often than expected: some
    /// device configurations don't expose distance even though step
    /// counting works fine. 0.75 m matches Apple's documented adult
    /// running stride average and is what apps like Strava use as
    /// the indoor fallback.
    private static let defaultStrideMeters: Double = 0.75

    private func startPedometerUpdates(from start: Date) {
        log.info("[pedometer] entry, start=\(start.timeIntervalSince1970, privacy: .public)")

        guard CMPedometer.isStepCountingAvailable() else {
            lastError = "Step counting not available on this device."
            log.error("[pedometer] isStepCountingAvailable=false — bail")
            return
        }

        let auth = CMPedometer.authorizationStatus()
        log.info("[pedometer] auth=\(auth.rawValue, privacy: .public) stepAvail=\(CMPedometer.isStepCountingAvailable(), privacy: .public) distanceAvail=\(CMPedometer.isDistanceAvailable(), privacy: .public) cadenceAvail=\(CMPedometer.isCadenceAvailable(), privacy: .public) paceAvail=\(CMPedometer.isPaceAvailable(), privacy: .public)")
        switch auth {
        case .denied, .restricted:
            lastError = "Motion access denied — enable in Settings → Privacy & Security → Motion & Fitness → AARC."
            log.error("[pedometer] auth denied/restricted — bail")
            return
        case .notDetermined:
            log.info("[pedometer] auth notDetermined — startUpdates should prompt")
        case .authorized:
            log.info("[pedometer] auth authorized")
        @unknown default:
            log.info("[pedometer] auth unknown value")
        }

        let p = CMPedometer()
        let stride = Self.defaultStrideMeters
        let distanceAvailable = CMPedometer.isDistanceAvailable()
        log.info("[pedometer] calling startUpdates…")
        // @Sendable strips the implicit @MainActor isolation Swift 6 would
        // inherit from this @MainActor method. Without it, the runtime
        // inserts dispatch_assert_queue(main) at the closure's entry and
        // traps on the first callback (CMPedometer fires on its own private
        // dispatch queue). That trap is exactly what was killing the
        // phone-only treadmill session silently — symptom: "no data".
        let handler: @Sendable (CMPedometerData?, Error?) -> Void = { [weak self] data, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.lastError = "Pedometer: \(error.localizedDescription)"
                    self?.log.error("[pedometer.cb] error: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let data else {
                Task { @MainActor [weak self] in
                    self?.log.error("[pedometer.cb] both data and error nil — bizarre")
                }
                return
            }

            let stepCount = data.numberOfSteps.doubleValue
            let reportedDistance = data.distance?.doubleValue ?? 0
            let reportedDistanceIsNil = (data.distance == nil)
            let cumulativeMeters: Double = {
                if distanceAvailable, reportedDistance > 0 {
                    return reportedDistance
                }
                return stepCount * stride
            }()
            let spm: Double? = data.currentCadence.map { $0.doubleValue * 60 }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.info("[pedometer.cb] steps=\(stepCount, privacy: .public) reportedDist=\(reportedDistance, privacy: .public) wasNil=\(reportedDistanceIsNil, privacy: .public) cumulative=\(cumulativeMeters, privacy: .public) cadence=\(spm ?? -1, privacy: .public)")
                self.distanceMeters = cumulativeMeters
                self.currentCadenceSPM = spm
                self.paceWindow.append((t: .now, d: cumulativeMeters))
                let cutoff = Date().addingTimeInterval(-self.paceWindowSeconds)
                self.paceWindow.removeAll { $0.t < cutoff }
            }
        }
        p.startUpdates(from: start, withHandler: handler)
        self.pedometer = p
        log.info("[pedometer] startUpdates returned — waiting for first callback")
    }

    // MARK: - Location

    private func startLocationUpdates(indoor: Bool) {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.distanceFilter = 5 // meters
        // Lets the OS scale down GPS when phone is in pocket / screen off.
        manager.pausesLocationUpdatesAutomatically = false
        // Background updates need the `location` UIBackgroundMode (set in
        // Info.plist). Without `Always` auth iOS will still keep updates
        // flowing while the app is "in use" — which Live Activity counts as.
        manager.allowsBackgroundLocationUpdates = !indoor
        manager.showsBackgroundLocationIndicator = false
        if !indoor {
            manager.startUpdatingLocation()
        }
        self.locationManager = manager
    }

    /// Build a `LiveMetrics` snapshot and hand it to the consumer.
    /// Called on a 1Hz timer.
    private func publishTick() {
        guard isActive, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let currentPace = currentPaceSecPerKm()
        let avgPace = (distanceMeters > 0) ? (elapsed / (distanceMeters / 1000)) : 0
        let metrics = LiveMetrics(
            elapsed: elapsed,
            distanceMeters: distanceMeters,
            currentPaceSecPerKm: currentPace,
            avgPaceSecPerKm: avgPace,
            currentHeartRate: nil,
            energyKcal: 0,
            cadenceStepsPerMinute: currentCadenceSPM,
            lastSplit: nil,
            state: .running
        )
        // Heartbeat every 2s so Console.app can distinguish "iOS
        // suspended us" (heartbeat stops) from "pedometer never
        // fired" (heartbeat continues but distance stays 0).
        if Int(elapsed) % 2 == 0 {
            log.info("[tick] elapsed=\(Int(elapsed), privacy: .public)s dist=\(self.distanceMeters, privacy: .public)m pace=\(currentPace ?? -1, privacy: .public) cadence=\(self.currentCadenceSPM ?? -1, privacy: .public)")
        }
        LiveMetricsConsumer.shared.ingest(metrics)
    }

    private func currentPaceSecPerKm() -> Double? {
        let cutoff = Date().addingTimeInterval(-paceWindowSeconds)
        let recent = paceWindow.filter { $0.t >= cutoff }
        guard recent.count >= 2,
              let first = recent.first, let last = recent.last,
              last.t > first.t else { return nil }
        let metres = last.d - first.d
        let seconds = last.t.timeIntervalSince(first.t)
        guard metres > 1, seconds > 0.5 else { return nil }
        let secPerMeter = seconds / metres
        return secPerMeter * 1000
    }

    private func startPublishTimer() {
        publishTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishTick()
            }
        }
        publishTimer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

// MARK: - CLLocationManagerDelegate

extension PhoneWorkoutSession: @preconcurrency CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // Filter on accuracy, snapshot the values we need, then hop to
        // MainActor to mutate our @Observable state.
        let usable = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 30 }
        guard !usable.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for location in usable {
                if let prev = self.lastLocation {
                    let delta = location.distance(from: prev)
                    // Reject zero-speed jitter (< 0.5 m moves while stationary)
                    if delta > 0.5 {
                        self.distanceMeters += delta
                    }
                }
                self.lastLocation = location
                self.paceWindow.append((t: location.timestamp, d: self.distanceMeters))
                let cutoff = Date().addingTimeInterval(-self.paceWindowSeconds * 2)
                if self.paceWindow.first?.t ?? .distantFuture < cutoff {
                    self.paceWindow.removeAll { $0.t < cutoff }
                }
                self.pendingRouteLocations.append(location)
            }
            // Flush route buffer periodically so we don't lose the
            // trail if the app is killed.
            if self.pendingRouteLocations.count >= 20,
               let routeBuilder = self.routeBuilder {
                let toFlush = self.pendingRouteLocations
                self.pendingRouteLocations.removeAll()
                Task.detached {
                    try? await routeBuilder.insertRouteData(toFlush)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.lastError = "Location error: \(error.localizedDescription)"
            self?.log.error("Location error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum PhoneWorkoutError: Error, LocalizedError {
    case healthKitUnavailable
    case locationNotAuthorized
    case motionNotAuthorized

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return "HealthKit is not available on this device."
        case .locationNotAuthorized:
            return "Phone-only outdoor runs need Location permission. Open Settings → Permissions."
        case .motionNotAuthorized:
            return "Phone-only treadmill needs Motion & Fitness permission. Open Settings → AARC → Motion & Fitness and enable it."
        }
    }
}
