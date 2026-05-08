import Foundation
import HealthKit
import AVFoundation
import Speech

@Observable
@MainActor
final class PermissionsManager {
    private let healthStore = HKHealthStore()

    var healthKitAuthorized: Bool = false
    var microphoneAuthorized: Bool = false
    var speechAuthorized: Bool = false

    var healthKitDescription: String {
        HKHealthStore.isHealthDataAvailable()
            ? (healthKitAuthorized ? "Authorized" : "Not requested")
            : "Unavailable"
    }
    var microphoneDescription: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "Authorized"
        case .denied: return "Denied"
        case .undetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
    var speechDescription: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    func refresh() async {
        microphoneAuthorized = AVAudioApplication.shared.recordPermission == .granted
        speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        // HK status is per-type; we treat "any read+write granted" as a soft signal here.
        healthKitAuthorized = HKHealthStore.isHealthDataAvailable()
            && healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func requestHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
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
        do {
            try await healthStore.requestAuthorization(toShare: toShare, read: toRead)
            await refresh()
        } catch {
            // Surface in UI later; for Phase 0 the row is enough signal.
        }
    }

    func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
        await refresh()
    }

    func requestSpeechRecognition() async {
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume(returning: ()) }
        }
        await refresh()
    }
}
