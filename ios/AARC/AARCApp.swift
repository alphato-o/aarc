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
                    // Pre-warm the audio session so the first companion
                    // utterance doesn't pay activation latency. Initialiser
                    // configures the category; activate happens on first
                    // speak.
                    _ = AudioPlaybackManager.shared
                    _ = LocalTTS.shared
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
