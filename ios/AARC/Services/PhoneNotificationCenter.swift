import Foundation
import Observation
import OSLog
import UIKit
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
final class PhoneNotificationCenter: NSObject {
    static let shared = PhoneNotificationCenter()

    override init() {
        super.init()
        // Become the UNUserNotificationCenter delegate so the visual UI
        // (lock-screen banner + Notification Center entry + watch mirror)
        // shows even while AARC is in the foreground. Without a delegate,
        // iOS silently drops the visible alert while the app is active —
        // which manifests as "the watch buzzes but no card appears".
        UNUserNotificationCenter.current().delegate = self
    }

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
        title: String = "AARC run ready",
        body: String = "Open AARC on your Apple Watch to start tracking."
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
        // Stay at the default .active interruption level. .timeSensitive
        // requires an Apple-granted entitlement; without it iOS silently
        // downgrades the notification to .passive, which suppresses banner +
        // sound — including the watch mirror's tappable card. .active is the
        // standard alert level and works without entitlements.

        // 4-second trigger so the user has time to lock the phone after
        // tapping Start. iOS only mirrors notifications to the watch when
        // the iPhone is locked or off-wrist; firing immediately with the
        // phone in hand kills the mirror condition.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)
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

// MARK: - UNUserNotificationCenterDelegate

extension PhoneNotificationCenter: UNUserNotificationCenterDelegate {
    /// Called for every notification the system is about to present
    /// while the host app is in the foreground. The default behaviour
    /// is to suppress the visual UI entirely — which also suppresses
    /// the Apple Watch mirror in many cases. We explicitly request
    /// banner + list + sound so the notification surfaces on the
    /// phone AND mirrors to the watch as a real, tappable card.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// The user tapped the notification (on iPhone or, after mirror,
    /// on the watch). On iPhone the app is already open; on the watch
    /// watchOS launches AARCWatch, which on launch consumes the queued
    /// WC startWorkout message. We don't need to do anything in this
    /// handler beyond clearing the notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
