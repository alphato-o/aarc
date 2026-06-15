import SwiftUI
import SwiftData

@main
struct AARCApp: App {
    init() {
        // MUST happen promptly at launch (not in a view's task): when the
        // watch starts mirroring a workout, the system background-launches
        // this app and calls the handler — if it isn't installed yet, the
        // mirrored session is missed.
        MirroringReceiver.shared.install()
        // Voice-archive cloud sync defaults ON now that R2 is enabled
        // (user-controllable later; the uploader stops on 503 anyway).
        if UserDefaults.standard.object(forKey: "aarc.sync.audioEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "aarc.sync.audioEnabled")
        }
        // Sentry (aarc-ios project) — default DSN so handled-error
        // reporting works out of the box; the Settings field overrides.
        if UserDefaults.standard.string(forKey: CrashReporter.dsnDefaultsKey)?.isEmpty != false {
            UserDefaults.standard.set(
                "https://76f5937f7ff8e394a4d9a24d1601b5e8@o4511545890701312.ingest.us.sentry.io/4511545896337408",
                forKey: CrashReporter.dsnDefaultsKey
            )
        }
        // Bridge handled-error reports into the run event log so they
        // show up in the Control Room tail + post-run replay.
        CrashReporter.setEventSink { kind, message in
            Task { @MainActor in
                RunEventLog.shared.record(kind, message)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(PhoneSession.shared)
                .environment(LiveMetricsConsumer.shared)
                .preferredColorScheme(.dark)
                .task {
                    if ShareCardPreviewHarness.enabled { ShareCardPreviewHarness.run() }
                    PhoneSession.shared.activate()
                    // Pre-warm the audio session so the first companion
                    // utterance doesn't pay activation latency. Initialiser
                    // configures the category; activate happens on first
                    // speak.
                    _ = AudioPlaybackManager.shared
                    _ = LocalTTS.shared
                    // Touch the notification center so its init runs and
                    // registers as UNUserNotificationCenter.delegate before
                    // anything tries to schedule. Without an early delegate
                    // hookup, iOS suppresses foreground banners (and the
                    // watch mirror with them).
                    _ = PhoneNotificationCenter.shared
                    // Best-effort HealthKit auth on launch so the watch's
                    // workouts can be read back into our history. If the
                    // user has already responded, this is a no-op; if they
                    // denied, we silently fall back to stub records.
                    await PermissionsManager.shared.requestHealthKit()
                    // Push the most recent existing run to the home-screen
                    // widget. Runs that landed before the widget shipped
                    // (or while the App Group entitlement wasn't yet
                    // provisioned) only get into the widget container via
                    // this backfill — otherwise the widget shows "No runs
                    // yet" forever.
                    LastRunSnapshotStore.backfillFromHistory()
                    // Retry any run-diagnostics uploads that didn't make
                    // it out last session (e.g. ended the run in a tunnel).
                    RunEventLog.shared.uploadPendingRuns()
                    // Backfill the cloud dashboard with historical runs so
                    // their performance charts render. Cheap when the
                    // done-set already covers all of history.
                    RunHistoryBackfill.backfillAll()
                    // Endpoint failover probe loop (CF Worker ↔ US gateway).
                    EndpointManager.shared.startProbing()
                    // Pull the dashboard-edited personal-troll facts.
                    PersonalContextStore.shared.refreshFromServer()
                }
                // Dashboard QR sign-in: the iPhone Camera app reads the
                // QR on the web dashboard and opens aarc://dash-auth?...,
                // which lands here and approves the session.
                .onOpenURL { url in
                    DashboardAuth.shared.handle(url: url)
                }
        }
        .modelContainer(PersistenceStore.shared.container)
    }
}
