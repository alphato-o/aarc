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
                .task {
                    PhoneSession.shared.activate()
                    // Best-effort HealthKit auth on launch so the watch's
                    // workouts can be read back into our history. If the
                    // user has already responded, this is a no-op; if they
                    // denied, we silently fall back to stub records.
                    await PermissionsManager.shared.requestHealthKit()
                }
        }
        .modelContainer(PersistenceStore.shared.container)
    }
}
