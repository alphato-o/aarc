import Foundation
import HealthKit
import CoreLocation
import AARCKit

/// The watch-side workout owner. Hosts the `HKWorkoutSession`,
/// `HKLiveWorkoutBuilder`, and `HKWorkoutRouteBuilder`. Publishes a
/// `LiveMetrics` snapshot at 1 Hz that the watch UI binds to (and that
/// will, in §1.2, be streamed to the iPhone via WatchConnectivity).
///
/// Apple owns all tracking: distance, pace, HR, energy, route smoothing.
/// We observe what the builder publishes and compute one trivial derived
/// value (current pace = distance delta / time delta over a 30 s window).
@Observable
@MainActor
final class WorkoutSessionHost: NSObject {
    static let shared = WorkoutSessionHost()

    // Published state for the UI.
    var state: WorkoutState = .idle
    var liveMetrics: LiveMetrics = .zero
    var lastError: String?

    // Identity for this run — stamped into HK metadata at finalise.
    var currentRunId: UUID?
    var currentRunIsTestData: Bool = true
    var currentRunType: RunType = .outdoor

    // HK plumbing.
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var location: LocationProvider?

    private var startedAt: Date?
    private var ticker: Task<Void, Never>?
    private var lastPublishedSplitKm: Int = 0

    private var distanceWindow: [(Date, Double)] = []  // for current-pace derivation

    private var healthStore: HKHealthStore { HealthKitClient.shared.store }

    // MARK: - Lifecycle

    func startOutdoorRun(
        runId: UUID = UUID(),
        isTestData: Bool,
        skipHealthKitWrite: Bool
    ) async throws {
        try await start(locationType: .outdoor, runId: runId, isTestData: isTestData, skipHealthKitWrite: skipHealthKitWrite)
    }

    func startTreadmillRun(
        runId: UUID = UUID(),
        isTestData: Bool,
        skipHealthKitWrite: Bool
    ) async throws {
        try await start(locationType: .indoor, runId: runId, isTestData: isTestData, skipHealthKitWrite: skipHealthKitWrite)
    }

    private func start(
        locationType: HKWorkoutSessionLocationType,
        runId: UUID,
        isTestData: Bool,
        skipHealthKitWrite: Bool
    ) async throws {
        guard state == .idle || state == .ended else { return }

        try await HealthKitClient.shared.requestAuthorization()

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = locationType

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

        // Belt-and-suspenders: even though the data source is supposed
        // to auto-enable types for .running, in practice some setups
        // come up without HR / distance / energy populated. Explicit
        // enable removes the ambiguity.
        let typesToCollect: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .distanceWalkingRunning,
            .activeEnergyBurned,
            .stepCount,
        ]
        for id in typesToCollect {
            if let type = HKObjectType.quantityType(forIdentifier: id) {
                dataSource.enableCollection(for: type, predicate: nil)
            }
        }

        builder.dataSource = dataSource
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder
        self.currentRunId = runId
        self.currentRunIsTestData = isTestData
        self.currentRunType = (locationType == .indoor) ? .treadmill : .outdoor
        self.skipHealthKitWriteForCurrentRun = skipHealthKitWrite
        self.startedAt = .now
        self.lastPublishedSplitKm = 0
        self.distanceWindow = []
        self.lastError = nil

        let beginDate = Date()
        session.startActivity(with: beginDate)
        try await builder.beginCollection(at: beginDate)

        if locationType == .outdoor {
            self.routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
            self.location = LocationProvider { [weak self] locs in
                Task { @MainActor in self?.routeBuilder?.insertRouteData(locs) { _, _ in } }
            }
            self.location?.start()
        }

        state = .running
        startTicker()

        // Tell the phone the workout has started so it can begin
        // observing live metrics. Queued + guaranteed delivery.
        WatchSession.shared.sendStateEvent(
            .workoutStarted(runId: runId, startedAt: startedAt ?? .now)
        )
    }

    func pause() {
        guard state == .running else { return }
        session?.pause()
        // delegate flips state to .paused
        WatchSession.shared.sendStateEvent(.workoutPaused)
    }

    func resume() {
        guard state == .paused else { return }
        session?.resume()
        WatchSession.shared.sendStateEvent(.workoutResumed)
    }

    /// End the run. Honours `skipHealthKitWrite`: when set, abandons the
    /// session before `finishWorkout` so nothing lands in HK. Returns the
    /// finalised workout's UUID if we wrote one.
    @discardableResult
    func endRun() async -> UUID? {
        guard let session, let builder, state != .ended, state != .idle else { return nil }
        location?.stop()
        location = nil
        ticker?.cancel()
        ticker = nil

        let endDate = Date()
        session.end()

        // Stamp metadata BEFORE finalising. Even if we abandon, harmless.
        let metadata: [String: Any] = [
            HKMetadataKeys.runId: currentRunId?.uuidString ?? "",
            HKMetadataKeys.testData: currentRunIsTestData,
            HKMetadataKeys.createdAt: startedAt ?? endDate,
            HKMetadataKeys.appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
        ]
        try? await builder.addMetadata(metadata)

        if skipHealthKitWriteForCurrentRun {
            // Do NOT call finishWorkout. Abandon the builder; nothing is written.
            self.session = nil
            self.builder = nil
            self.routeBuilder = nil
            state = .ended
            return nil
        }

        do {
            try await builder.endCollection(at: endDate)
            let workout = try await builder.finishWorkout()
            if let workout, let routeBuilder {
                try? await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
            self.session = nil
            self.builder = nil
            self.routeBuilder = nil
            state = .ended
            if let uuid = workout?.uuid {
                WatchSession.shared.sendStateEvent(.workoutEnded(healthKitWorkoutUUID: uuid))
            }
            return workout?.uuid
        } catch {
            lastError = error.localizedDescription
            // Leave session/builder set so we can later retry; for now
            // also surface .ended so the UI can move on.
            state = .ended
            return nil
        }
    }

    // MARK: - 1Hz publisher

    private var skipHealthKitWriteForCurrentRun = false

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state == .running || self.state == .paused {
                self.refreshMetrics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshMetrics() {
        guard let builder, let startedAt else { return }
        let elapsed = builder.elapsedTime  // Apple-managed, excludes paused time
        let distance = quantitySum(.distanceWalkingRunning, unit: .meter())
        let energy = quantitySum(.activeEnergyBurned, unit: .kilocalorie())
        let hr = quantityRecent(.heartRate, unit: HKUnit(from: "count/min"))

        // Maintain a rolling 30s window of (timestamp, distance) for current pace.
        let now = Date()
        distanceWindow.append((now, distance))
        let cutoff = now.addingTimeInterval(-30)
        distanceWindow.removeAll { $0.0 < cutoff }
        let currentPace = derivedPace(distanceWindow)

        let avgPace = distance > 0 ? (elapsed / (distance / 1000)) : 0

        // Detect new km splits.
        let kmCount = Int(distance / 1000)
        var split: Split? = nil
        if kmCount > lastPublishedSplitKm {
            let kmIndex = lastPublishedSplitKm + 1
            let splitDuration = elapsed - Double(lastPublishedSplitKm) * (avgPace > 0 ? avgPace : 0)
            split = Split(
                kmIndex: kmIndex,
                durationSeconds: max(splitDuration, 0),
                paceSecPerKm: splitDuration > 0 ? splitDuration : avgPace,
                avgHeartRate: hr
            )
            lastPublishedSplitKm = kmIndex
        }

        liveMetrics = LiveMetrics(
            elapsed: elapsed,
            distanceMeters: distance,
            currentPaceSecPerKm: currentPace,
            avgPaceSecPerKm: avgPace,
            currentHeartRate: hr,
            energyKcal: energy,
            lastSplit: split,
            state: state
        )

        // Push to the iPhone. Best-effort; drops are fine because the
        // watch keeps writing to HealthKit independently.
        WatchSession.shared.sendLiveMetrics(liveMetrics)

        _ = startedAt  // silence unused for now
    }

    private func quantitySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) -> Double {
        guard let builder, let type = HKObjectType.quantityType(forIdentifier: id) else { return 0 }
        return builder.statistics(for: type)?.sumQuantity()?.doubleValue(for: unit) ?? 0
    }

    private func quantityRecent(_ id: HKQuantityTypeIdentifier, unit: HKUnit) -> Double? {
        guard let builder, let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        return builder.statistics(for: type)?.mostRecentQuantity()?.doubleValue(for: unit)
    }

    private func derivedPace(_ window: [(Date, Double)]) -> Double? {
        guard let first = window.first, let last = window.last else { return nil }
        let dt = last.0.timeIntervalSince(first.0)
        let dd = last.1 - first.1
        guard dt > 5, dd > 5 else { return nil }  // need at least a few seconds of motion
        let kmPerSec = (dd / 1000) / dt
        guard kmPerSec > 0 else { return nil }
        return 1 / kmPerSec  // sec per km
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutSessionHost: @preconcurrency HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .notStarted, .prepared: self.state = .idle
            case .running: self.state = .running
            case .paused: self.state = .paused
            case .ended, .stopped: self.state = .ended
            @unknown default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutSessionHost: @preconcurrency HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // The 1Hz ticker handles UI refresh; no extra work needed here.
        // Kept for delegate conformance; we may fan out events later.
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Auto-pause / lap markers — ignore in §1.1.
    }
}

// MARK: - LiveMetrics convenience

private extension LiveMetrics {
    static let zero = LiveMetrics(
        elapsed: 0,
        distanceMeters: 0,
        currentPaceSecPerKm: nil,
        avgPaceSecPerKm: 0,
        currentHeartRate: nil,
        energyKcal: 0,
        lastSplit: nil,
        state: .idle
    )
}
