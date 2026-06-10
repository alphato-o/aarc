import SwiftUI
import WatchKit

@main
struct AARCWatchApp: App {
    /// Delegate handles early WC activation + HKHealthStore.startWatchApp
    /// launches from the iPhone (the reliable phone→watch start channel).
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WatchSession.shared)
                .environment(WorkoutSessionHost.shared)
                // Redundant with the delegate's activation (activate() is
                // idempotent) — kept as belt-and-braces.
                .task { WatchSession.shared.activate() }
        }
    }
}
