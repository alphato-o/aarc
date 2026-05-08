import SwiftUI

@main
struct AARCWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WatchSession.shared)
                .environment(WorkoutSessionHost.shared)
                .task { WatchSession.shared.activate() }
        }
    }
}
