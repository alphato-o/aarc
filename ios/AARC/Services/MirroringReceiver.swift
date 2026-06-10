import Foundation
import HealthKit
import Observation
import OSLog
import AARCKit

/// iPhone-side endpoint for HKWorkoutSession mirroring (iOS 17+) — the
/// Apple-blessed multi-device workout channel (WWDC23). When the watch
/// starts a workout and mirrors it, the SYSTEM launches this app in the
/// background and delivers a mirrored `HKWorkoutSession` through
/// `workoutSessionMirroringStartHandler`. From then on:
///   - session state (running/paused/ended) syncs automatically,
///   - the watch streams `MirrorPayload`s (identity + 1 Hz metrics)
///     over `sendToRemoteWorkoutSession`,
///   - this side can pause/resume/stop the workout DIRECTLY on the
///     mirrored session object.
/// None of it rides WatchConnectivity — this is the redundant, modern
/// path that keeps working when the WC link wedges. WC remains as
/// fallback; while a mirror is live, the WC copy of liveMetrics is
/// ignored to avoid double ingestion.
///
/// The handler MUST be installed promptly at app launch (App.init) —
/// installing it in a view's onAppear misses background launches, the
/// most common community failure with this API.
@Observable
@MainActor
final class MirroringReceiver: NSObject {
    static let shared = MirroringReceiver()

    private let store = HKHealthStore()
    private let decoder = JSONDecoder()
    private let log = Logger(subsystem: "club.aarun.AARC", category: "Mirror")

    /// Strong reference required — the mirrored session deallocates
    /// silently otherwise (its delegate is weak).
    private(set) var mirroredSession: HKWorkoutSession?
    var isMirroring: Bool { mirroredSession != nil }
    /// Identity announced by the watch for the current mirrored run.
    private(set) var currentRunId: UUID?

    /// Install the mirroring start handler. Called from AARCApp.init.
    /// The handler may fire MULTIPLE times per workout: every Bluetooth
    /// reconnection delivers a brand-new session instance — treat it as
    /// "replace my current session", not "a workout started".
    func install() {
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor [weak self] in
                self?.adopt(session)
            }
        }
        log.info("[mirror] start handler installed")
    }

    private func adopt(_ session: HKWorkoutSession) {
        mirroredSession = session
        session.delegate = self
        log.info("[mirror] adopted mirrored session (state=\(session.state.rawValue))")
    }

    /// Phone-side End: stop the activity directly on the mirrored
    /// session — propagates to the watch natively. Redundant with the
    /// WC .endWorkout event; either arriving first wins.
    func endFromPhone() {
        guard let session = mirroredSession else { return }
        session.stopActivity(with: .now)
        log.info("[mirror] stopActivity sent from phone")
    }

    // MARK: - Inbound payloads

    private func handle(payloads: [Data]) {
        for data in payloads {
            guard let payload = try? decoder.decode(MirrorPayload.self, from: data) else {
                log.error("[mirror] payload decode failed — build drift?")
                continue
            }
            switch payload {
            case .identity(let runId, let runType, let personalityId, let startedAt):
                log.info("[mirror] identity \(runId.uuidString.prefix(8), privacy: .public)")
                currentRunId = runId
                LiveMetricsConsumer.shared.pendingRunType = runType
                LiveMetricsConsumer.shared.pendingPersonalityId = personalityId
                LiveMetricsConsumer.shared.ingestStarted(runId: runId, startedAt: startedAt)
            case .metrics(let metrics):
                LiveMetricsConsumer.shared.ingest(metrics)
            }
        }
    }
}

extension MirroringReceiver: @preconcurrency HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.log.info("[mirror] state \(fromState.rawValue) → \(toState.rawValue)")
            switch toState {
            case .paused:
                LiveMetricsConsumer.shared.ingestPaused()
            case .running where fromState == .paused:
                LiveMetricsConsumer.shared.ingestResumed()
            case .ended, .stopped:
                // Persistence still rides the WC workoutEnded event (it
                // carries the HK workout UUID, which only exists after
                // finishWorkout on the watch). Here we just drop the
                // mirror reference.
                self.mirroredSession = nil
                self.currentRunId = nil
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.log.error("[mirror] session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            self.handle(payloads: data)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        let errText = error?.localizedDescription
        Task { @MainActor in
            self.log.info("[mirror] disconnected (\(errText ?? "clean", privacy: .public)) — system will redeliver on reconnect")
            // This session object is dead and never reusable. If the run
            // is still live on the watch, the system auto-reconnects and
            // the start handler delivers a FRESH session; WC carries the
            // metrics in the meantime.
            self.mirroredSession = nil
        }
    }
}
