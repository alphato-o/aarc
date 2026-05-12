import Foundation
import HealthKit
import AVFoundation
import Speech
import UserNotifications

@Observable
@MainActor
final class PermissionsManager {
    static let shared = PermissionsManager()

    private let healthStore = HKHealthStore()

    var healthKitAuthorized: Bool = false
    var microphoneAuthorized: Bool = false
    var speechAuthorized: Bool = false
    var notificationsAuthorized: Bool = false
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

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
    var notificationDescription: String {
        switch notificationStatus {
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        case .denied: return "Denied"
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
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
        notificationsAuthorized = (notificationStatus == .authorized || notificationStatus == .provisional)
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
        _ = await Self.requestMicrophonePermission()
        await refresh()
    }

    func requestSpeechRecognition() async {
        _ = await Self.requestSpeechRecognitionAuthorization()
        await refresh()
    }

    func requestNotifications() async {
        _ = await PhoneNotificationCenter.shared.requestAuthorizationIfNeeded()
        await refresh()
    }

    /// Off-MainActor helper. SFSpeechRecognizer's callback fires on an
    /// arbitrary queue; calling `withCheckedContinuation` from inside a
    /// `@MainActor` function in Swift 6 strict concurrency trips a
    /// dispatch-queue assertion when the continuation resumes. Doing the
    /// authorization request from a `nonisolated` static helper sidesteps
    /// the cross-isolation resume path; the @MainActor caller awaits the
    /// final value and updates state on its own actor.
    nonisolated private static func requestSpeechRecognitionAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Symmetric helper for the mic. The async API on iOS 17+ already
    /// returns a `Bool`, but we keep it nonisolated for consistency with
    /// the speech path.
    nonisolated private static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
