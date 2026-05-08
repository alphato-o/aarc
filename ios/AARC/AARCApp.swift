import SwiftUI
import SwiftData

@main
struct AARCApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(PhoneSession.shared)
                .environment(LiveMetricsConsumer.shared)
                .preferredColorScheme(.dark)
                .task { PhoneSession.shared.activate() }
        }
        .modelContainer(PersistenceStore.shared.container)
    }
}
