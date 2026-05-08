import Foundation
import HealthKit

/// Thin wrapper around `HKHealthStore` for the watch side. Only exists to
/// centralise the auth request and expose a shared store to
/// `WorkoutSessionHost`.
@MainActor
final class HealthKitClient {
    static let shared = HealthKitClient()

    let store = HKHealthStore()

    /// Whether HealthKit data is available on this watch.
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Request the auth scope we need to host running workouts.
    /// Idempotent — Apple's auth sheet is only shown once per type.
    func requestAuthorization() async throws {
        guard isAvailable else { return }
        let workout = HKObjectType.workoutType()
        let route = HKSeriesType.workoutRoute()
        let toShare: Set<HKSampleType> = [workout, route]
        let toRead: Set<HKObjectType> = [
            workout,
            route,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        ]
        try await store.requestAuthorization(toShare: toShare, read: toRead)
    }

    /// "Are we cleared to run a workout?" Used by the Start button gating.
    var canHostWorkouts: Bool {
        isAvailable
            && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }
}
