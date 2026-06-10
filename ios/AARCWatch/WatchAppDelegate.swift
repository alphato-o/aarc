import WatchKit
import HealthKit
import OSLog
import AARCKit

/// Watch app delegate. Two reliability jobs:
///
/// 1. `applicationDidFinishLaunching` activates WatchConnectivity at the
///    earliest possible moment — before SwiftUI's `.task` — closing the
///    race where a queued command arrived before the session delegate
///    was installed and was silently dropped.
///
/// 2. `handle(_:)` receives `HKHealthStore.startWatchApp` launches from
///    the iPhone (the Apple Fitness-style channel that background-
///    launches this app even when it isn't running). The run parameters
///    (runId, personality) travel separately via applicationContext; the
///    activation snapshot in WatchSession consumes them. If they haven't
///    arrived shortly after the launch, we start anyway with local
///    defaults — a run with a default personality beats no run, and the
///    phone adopts whatever runId we announce (local-first rule).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private let log = Logger(subsystem: "club.aarun.AARC", category: "WC")

    func applicationDidFinishLaunching() {
        Task { @MainActor in
            WatchSession.shared.activate()
        }
        log.info("[watch] didFinishLaunching — WC activation kicked")
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let runType: RunType = (workoutConfiguration.locationType == .indoor) ? .treadmill : .outdoor
        log.info("[watch] startWatchApp launch received (locationType=\(workoutConfiguration.locationType.rawValue))")
        Task { @MainActor in
            // Give the applicationContext start command (runId +
            // personality) a moment to land via WatchSession's activation
            // snapshot — it usually beats us here. If it already started
            // the run, we're done.
            for _ in 0..<10 {   // up to ~5s
                let phase = WorkoutSessionHost.shared.phase
                if phase != .idle && phase != .ended && phase != .error { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // No parameters arrived — start anyway with local defaults.
            // The phone adopts the runId we announce via workoutStarted.
            let phase = WorkoutSessionHost.shared.phase
            guard phase == .idle || phase == .ended || phase == .error else { return }
            self.log.info("[watch] startWatchApp: params never arrived — starting with defaults")
            WKInterfaceDevice.current().play(.notification)
            await WorkoutSessionHost.shared.beginRun(
                runType: runType,
                prepareScriptOnPhone: false
            )
        }
    }
}
