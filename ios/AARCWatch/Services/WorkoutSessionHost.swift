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
/// User-facing phases of a run on the watch — distinct from
/// `WorkoutState` (which mirrors HK's session state). The phase covers
/// the pre-workout flow (preparing, counting down) that has no HK
/// concept yet.
public enum WorkoutPhase: String, Sendable {
    case idle
    case preparing      // waiting for phone to generate the script
    case countingDown   // 3-2-1-GO before HK session begins
    case running
    case paused
    case ended
    case error          // script generation or HK auth failed
}

@Observable
@MainActor
final class WorkoutSessionHost: NSObject {
    static let shared = WorkoutSessionHost()

    // Published state for the UI.
    var state: WorkoutState = .idle
    var phase: WorkoutPhase = .idle
    var liveMetrics: LiveMetrics = .zero
    var lastError: String?

    /// Countdown seconds remaining (3, 2, 1, then 0 → start). UI binds.
    var countdownRemaining: Int = 0
    private var countdownTask: Task<Void, Never>?

    /// Pending parameters captured during preparing phase, used when
    /// the countdown completes and we actually start the HK session.
    private var pendingRunType: RunType = .treadmill
    private var pendingRunId: UUID?
    private var pendingIsTestData: Bool = true
    private var pendingSkipHealthKitWrite: Bool = false

    // Identity for this run — stamped into HK metadata at finalise.
    var currentRunId: UUID?
    var currentRunIsTestData: Bool = true
    var currentRunType: RunType = .outdoor

    // Diagnostics (visible on the active-run view's debug section).
    /// When the workout-builder delegate last fired with new samples.
    var lastSampleEventAt: Date?
    /// Cumulative count of sample-collection events per quantity type
    /// (e.g. "HKQuantityTypeIdentifierHeartRate" -> 12).
    var samplesPerType: [String: Int] = [:]
    /// Most recent set of types the delegate reported.
    var lastCollectedTypeShortNames: [String] = []
    /// HK authorisation status per type we care about, snapshot at start.
    var hkAuthSnapshot: [String: String] = [:]

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

    /// Begin the prepare → countdown → run flow, asking the phone to
    /// generate a script while the user waits on the spinner. Called by
    /// the watch UI button OR triggered remotely by a phone-initiated
    /// startWorkout (in which case the script is already done and
    /// `prepareScriptOnPhone: false` skips straight to the countdown).
    func beginRun(
        runType: RunType,
        runId: UUID = UUID(),
        isTestData: Bool = false,
        skipHealthKitWrite: Bool = false,
        personalityId: String = "roast_coach",
        prepareScriptOnPhone: Bool = true
    ) async {
        self.pendingRunType = runType
        self.pendingRunId = runId
        self.pendingIsTestData = isTestData
        self.pendingSkipHealthKitWrite = skipHealthKitWrite

        if prepareScriptOnPhone {
            self.phase = .preparing
            self.lastError = nil
            // Ask the phone to generate. The phone's PhoneSession route
            // handler will reply with .scriptReady or .scriptFailed,
            // which call into onScriptReady() / onScriptFailed() below.
            WatchSession.shared.sendStateEvent(
                .prepareWorkout(runId: runId, runType: runType, personalityId: personalityId)
            )
        } else {
            // Phone already has the script (phone-initiated flow);
            // jump straight to the countdown.
            beginCountdown()
        }
    }

    /// Phone replied that the script is ready. Move to countdown.
    /// Called by WatchSession on receipt of .scriptReady.
    func onScriptReady() {
        guard phase == .preparing else { return }
        beginCountdown()
    }

    /// Phone failed to generate. Surface the error; user can retry or
    /// skip the coach by tapping Start again from the error state.
    func onScriptFailed(reason: String) {
        guard phase == .preparing else { return }
        self.lastError = reason
        self.phase = .error
    }

    /// Cancel the prepare/countdown flow before it becomes a real
    /// workout (e.g. user changed their mind during the spinner).
    func cancelPreparation() {
        countdownTask?.cancel()
        countdownTask = nil
        phase = .idle
        lastError = nil
        pendingRunId = nil
    }

    private func beginCountdown() {
        phase = .countingDown
        countdownRemaining = 3
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.countdownRemaining = n
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.countdownRemaining = 0
            await self.startSessionFromCountdown()
        }
    }

    private func startSessionFromCountdown() async {
        do {
            try await start(
                locationType: pendingRunType == .treadmill ? .indoor : .outdoor,
                runId: pendingRunId ?? UUID(),
                isTestData: pendingIsTestData,
                skipHealthKitWrite: pendingSkipHealthKitWrite
            )
        } catch {
            self.lastError = error.localizedDescription
            self.phase = .error
        }
    }

    /// Direct-start path retained as a fallback for tests / no-coach
    /// runs. Skips the prepare + countdown flow entirely.
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
        for id in Self.typesToCollect {
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
        self.lastSampleEventAt = nil
        self.samplesPerType = [:]
        self.lastCollectedTypeShortNames = []
        self.hkAuthSnapshot = snapshotAuthStatus(for: Self.typesToCollect)

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
        // delegate flips state to .paused; mirror to phase for the UI.
        phase = .paused
        WatchSession.shared.sendStateEvent(.workoutPaused)
    }

    func resume() {
        guard state == .paused else { return }
        session?.resume()
        phase = .running
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
            phase = .ended
            if let uuid = workout?.uuid {
                WatchSession.shared.sendStateEvent(.workoutEnded(healthKitWorkoutUUID: uuid))
            }
            return workout?.uuid
        } catch {
            lastError = error.localizedDescription
            // Leave session/builder set so we can later retry; for now
            // also surface .ended so the UI can move on.
            state = .ended
            phase = .ended
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
            case .notStarted, .prepared:
                self.state = .idle
                // Don't downgrade phase here — preparing / countingDown
                // run BEFORE the HK session actually starts.
            case .running:
                self.state = .running
                self.phase = .running
            case .paused:
                self.state = .paused
                self.phase = .paused
            case .ended, .stopped:
                self.state = .ended
                self.phase = .ended
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
        let identifiers = collectedTypes.compactMap { ($0 as? HKQuantityType)?.identifier }
        Task { @MainActor in
            self.lastSampleEventAt = .now
            self.lastCollectedTypeShortNames = identifiers.map { Self.shortName(for: $0) }
            for id in identifiers {
                self.samplesPerType[Self.shortName(for: id), default: 0] += 1
            }
            // Pull a fresh snapshot — Apple's recommended pattern is to
            // refresh on the data event, not just on a timer.
            self.refreshMetrics()
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Auto-pause / lap markers — ignore in §1.1.
    }
}

// MARK: - Diagnostics helpers

extension WorkoutSessionHost {
    fileprivate static let typesToCollect: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .distanceWalkingRunning,
        .activeEnergyBurned,
        .stepCount,
    ]

    fileprivate static func shortName(for identifier: String) -> String {
        let prefix = "HKQuantityTypeIdentifier"
        if identifier.hasPrefix(prefix) {
            return String(identifier.dropFirst(prefix.count))
        }
        return identifier
    }

    fileprivate func snapshotAuthStatus(for ids: [HKQuantityTypeIdentifier]) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }
            let status = healthStore.authorizationStatus(for: type)
            out[Self.shortName(for: id.rawValue)] = Self.describe(status)
        }
        out["WorkoutType"] = Self.describe(healthStore.authorizationStatus(for: HKObjectType.workoutType()))
        return out
    }

    fileprivate static func describe(_ status: HKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .sharingDenied: return "sharingDenied"
        case .sharingAuthorized: return "sharingAuthorized"
        @unknown default: return "unknown"
        }
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
