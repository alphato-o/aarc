import Foundation
import Observation
import OSLog
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for the "open AARC on
/// your watch" wrist-cue notification fired when the iPhone initiates a
/// run.
///
/// Why a local notification: iOS does not allow apps to force-launch a
/// watchOS app from the phone (battery + UX restriction). The standard
/// workaround that NRC / Strava / Apple's own Workout use is a
/// notification on the phone that mirrors to the watch when the phone
/// is locked or off-wrist. The watch buzzes, the user sees a tappable
/// card, tap → watchOS launches AARC, which on launch consumes the
/// queued startWorkout from WatchConnectivity and begins the workout.
@Observable
@MainActor
final class PhoneNotificationCenter {
    static let shared = PhoneNotificationCenter()

    /// Latest known authorization status. Refreshed on each schedule
    /// attempt and on app foregrounding.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Surfaced by Settings so the user can see whether their last
    /// schedule actually went out.
    private(set) var lastScheduledAt: Date?
    private(set) var lastError: String?

    private let log = Logger(subsystem: "club.aarun.AARC", category: "Notifications")

    /// Notification identifiers we use so we can replace / cancel them
    /// without affecting unrelated notifications.
    enum Identifier {
        static let startCue = "aarc.startCue"
    }

    /// Thread identifier so multiple Start taps group together on the
    /// watch instead of stacking individual alerts.
    private let startCueThread = "aarc-start"

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
    }

    /// Idempotent — safe to call whenever the user might be about to
    /// schedule. Returns the final status.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        await refreshAuthorizationStatus()
        switch authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                log.info("Notification authorization granted=\(granted, privacy: .public)")
            } catch {
                log.error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
            await refreshAuthorizationStatus()
        default:
            break
        }
        return authorizationStatus
    }

    /// Schedules an immediate (1s) local notification with title +
    /// body, replacing any pending start-cue. iOS mirrors to the watch
    /// when the phone is locked / screen off / off-wrist.
    func scheduleStartCue(
        title: String = "Open AARC on your watch",
        body: String = "Tap to begin tracking your run."
    ) async {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized || status == .provisional else {
            lastError = "Notifications not authorized"
            log.info("scheduleStartCue skipped — status=\(status.rawValue, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = startCueThread
        content.sound = .default
        // High relevance so the watch surfaces it prominently.
        content.relevanceScore = 1.0
        if #available(iOS 16.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        // 1s trigger (UN requires >0). Long enough for the system to
        // schedule reliably; short enough that the user feels it
        // immediately on the wrist.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: Identifier.startCue,
            content: content,
            trigger: trigger
        )

        // Replace any pending start-cue rather than stacking.
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Identifier.startCue])

        do {
            try await UNUserNotificationCenter.current().add(request)
            lastScheduledAt = .now
            lastError = nil
            log.info("Start-cue notification scheduled")
        } catch {
            lastError = error.localizedDescription
            log.error("scheduleStartCue add failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelStartCue() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Identifier.startCue])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Identifier.startCue])
    }
}
