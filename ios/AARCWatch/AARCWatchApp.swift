import SwiftUI

@main
struct AARCWatchApp: App {
    private let session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(session)
                .task { session.activate() }
        }
    }
}
