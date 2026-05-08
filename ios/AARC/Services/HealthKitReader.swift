import Foundation
import HealthKit
import CoreLocation
import AARCKit

/// iPhone-side read-only window into HealthKit. The watch is the writer;
/// the phone reads workouts back to render history and to denormalise
/// snapshot fields onto our local `RunRecord`s.
actor HealthKitReader {
    static let shared = HealthKitReader()

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Try to fetch a specific HK workout by UUID. Returns nil if HK
    /// hasn't yet propagated the workout from the watch (this can take
    /// a few seconds after `finishWorkout`).
    func fetchWorkout(uuid: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: uuid)
        let workouts = try await sample(of: HKObjectType.workoutType(), predicate: predicate, limit: 1)
        return workouts.first as? HKWorkout
    }

    /// Try repeatedly with backoff. The watch's `finishWorkout` returns
    /// the UUID before the workout is necessarily queryable from the
    /// phone over HK sync. ~5s is enough in practice.
    func fetchWorkoutWithRetry(uuid: UUID, attempts: Int = 6) async throws -> HKWorkout? {
        for attempt in 0..<attempts {
            if let w = try? await fetchWorkout(uuid: uuid) {
                return w
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    /// All locations on the workout's route, ordered by time.
    func fetchRoute(for workout: HKWorkout) async throws -> [CLLocation] {
        // 1. Find the route series associated with this workout.
        let routePredicate = HKQuery.predicateForObjects(from: workout)
        let routeType = HKSeriesType.workoutRoute()
        let routes = try await sample(of: routeType, predicate: routePredicate, limit: HKObjectQueryNoLimit)
        guard let route = routes.first as? HKWorkoutRoute else { return [] }

        // 2. Stream all CLLocations off that series.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLLocation], Error>) in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let locations { collected.append(contentsOf: locations) }
                if done {
                    continuation.resume(returning: collected.sorted(by: { $0.timestamp < $1.timestamp }))
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Helpers

    /// Read distance from a finished workout (post-iOS 16 API).
    nonisolated func distanceMeters(_ workout: HKWorkout) -> Double {
        workout
            .statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?
            .doubleValue(for: .meter()) ?? 0
    }

    nonisolated func energyKcal(_ workout: HKWorkout) -> Double {
        workout
            .statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie()) ?? 0
    }

    /// "outdoor" / "treadmill" derived from the workout's HK metadata.
    nonisolated func runType(_ workout: HKWorkout) -> RunType {
        let isIndoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
        return isIndoor ? .treadmill : .outdoor
    }

    /// True if AARC stamped this workout with the test-data marker.
    nonisolated func isTestData(_ workout: HKWorkout) -> Bool {
        (workout.metadata?[HKMetadataKeys.testData] as? Bool) ?? false
    }

    /// AARC's runId stamped at finalise, if present.
    nonisolated func aarcRunId(_ workout: HKWorkout) -> UUID? {
        guard let s = workout.metadata?[HKMetadataKeys.runId] as? String else { return nil }
        return UUID(uuidString: s)
    }

    private func sample(of type: HKSampleType, predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
}
