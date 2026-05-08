import SwiftUI

@main
struct AARCWatchApp: App {
    private let session = WatchSession()
    private let workoutHost = WorkoutSessionHost()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(session)
                .environment(workoutHost)
                .task { session.activate() }
        }
    }
}
