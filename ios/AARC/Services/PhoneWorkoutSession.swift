import Foundation
import CoreLocation
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
/// MVP scope (phase 1):
///   - outdoor only (GPS distance / pace from CLLocationManager)
///   - no heart rate (phone has no HR sensor; HK live HR from a wrist-
///     worn watch can be wired in later)
///   - treadmill (CMPedometer-based) is a follow-up commit
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

    /// Accumulated distance in meters.
    private var distanceMeters: Double = 0
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
        guard !isActive else {
            log.info("PhoneWorkoutSession.start called while already active — ignoring")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw PhoneWorkoutError.healthKitUnavailable
        }
        let auth = CLLocationManager().authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            throw PhoneWorkoutError.locationNotAuthorized
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
        self.startedAt = now
        self.currentRunId = runId
        self.lastError = nil

        startLocationUpdates(indoor: runType == .treadmill)
        startPublishTimer()

        self.isActive = true

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
        LiveMetricsConsumer.shared.ingestPaused()
    }

    func resume() {
        guard isActive else { return }
        locationManager?.startUpdatingLocation()
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
            lastSplit: nil,
            state: .running
        )
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

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return "HealthKit is not available on this device."
        case .locationNotAuthorized:
            return "Phone-only outdoor runs need Location permission. Open Settings → Permissions."
        }
    }
}
