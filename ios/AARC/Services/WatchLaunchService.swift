import Foundation
import HealthKit
import OSLog
import AARCKit

/// Launches the AARC watch app via `HKHealthStore.startWatchApp(with:)` —
/// the same mechanism Apple Fitness uses. Unlike WatchConnectivity
/// messages, this background-launches the watch app even when it isn't
/// running, and doesn't depend on the watch app being reachable or the
/// phone being locked (the notification-mirroring path requires both).
///
/// The watch side receives the configuration in
/// `WatchAppDelegate.handle(_:)` and starts the run; the actual run
/// parameters (runId, personality) ride WatchConnectivity's
/// applicationContext in parallel.
@MainActor
enum WatchLaunchService {
    private static let store = HKHealthStore()
    private static let log = Logger(subsystem: "club.aarun.AARC", category: "WC")

    enum LaunchError: LocalizedError {
        case watchAppNotInstalled
        case notPaired
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .watchAppNotInstalled:
                return "iPhone's pairing registry says the watch app isn't installed (dev-install glitch). Reboot the watch or reinstall the watch app."
            case .notPaired:
                return "No paired Apple Watch."
            case .failed(let m):
                return m
            }
        }
    }

    /// Launch the watch app primed for a workout. Returns nil on success,
    /// or the error so the caller can surface it + fall back.
    static func launch(runType: RunType) async -> LaunchError? {
        // Pre-flight against the pairing registry — when it has lost the
        // watch app's install record (the 2026-06-10 failure), fail FAST
        // with the precise reason instead of timing out into mystery.
        guard PhoneSession.shared.isPaired else { return .notPaired }
        guard PhoneSession.shared.isWatchAppInstalled else { return .watchAppNotInstalled }

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = (runType == .treadmill) ? .indoor : .outdoor

        // Capture the logger locally — the @Sendable closure below can't
        // touch this enum's MainActor-isolated statics. Logger itself is
        // Sendable, so the captured value is safe off-main.
        let log = Self.log
        return await withCheckedContinuation { (cont: CheckedContinuation<LaunchError?, Never>) in
            // @Sendable: HealthKit may deliver this completion on a
            // background queue — an inferred-@MainActor closure would
            // trap there. Logger + continuation are both Sendable.
            let completion: @Sendable (Bool, (any Error)?) -> Void = { success, error in
                if success {
                    log.info("[phone] startWatchApp launched watch app")
                    cont.resume(returning: nil)
                } else {
                    let msg = error?.localizedDescription ?? "unknown startWatchApp failure"
                    log.error("[phone] startWatchApp FAILED: \(msg, privacy: .public)")
                    cont.resume(returning: .failed(msg))
                }
            }
            store.startWatchApp(with: config, completion: completion)
        }
    }
}
