import Foundation
import HealthKit

/// Counts and bulk-deletes AARC-tagged workouts in HealthKit.
/// Companion-data cleanup (local RunRecord rows) happens in the caller
/// because SwiftData's ModelContext is `@MainActor`-bound.
actor TestDataManager {
    static let shared = TestDataManager()

    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Predicate for every workout AARC ever wrote with the test-data tag.
    /// Matches workouts whose metadata contains `aarc.test_data: true`.
    private var testDataPredicate: NSPredicate {
        HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeys.testData,
            operatorType: .equalTo,
            value: NSNumber(value: true)
        )
    }

    func testWorkoutCount() async -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        do {
            return try await fetchTestWorkouts().count
        } catch {
            return 0
        }
    }

    /// Deletes every AARC-tagged workout from HealthKit. HK cascades the
    /// delete to associated samples (HR, distance, energy) and the route.
    /// Returns the deleted workouts' UUIDs so the caller can drop matching
    /// local RunRecord rows.
    @discardableResult
    func wipe() async throws -> [UUID] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let workouts = try await fetchTestWorkouts()
        guard !workouts.isEmpty else { return [] }
        let uuids = workouts.map(\.uuid)
        try await delete(workouts)
        return uuids
    }

    private func fetchTestWorkouts() async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: testDataPredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func delete(_ objects: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.delete(objects) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}
