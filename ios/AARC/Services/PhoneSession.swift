import Foundation
import WatchConnectivity
import OSLog
import AARCKit

/// iOS-side wrapper around `WCSession`. The watch sends `LiveMetrics`
/// 1 Hz via `sendMessageData` (best-effort) and workout state events via
/// `transferUserInfo` (queued + guaranteed).
///
/// Reliability posture (added after two total handover failures):
/// - EVERYTHING is logged (subsystem club.aarun.AARC, category WC) — the
///   old code discarded every error, which made both field failures
///   undiagnosable without a watch reboot.
/// - `isWatchAppInstalled` is tracked live. The 2026-06-10 failure was
///   the iPhone's pairing registry losing the watch app's install record
///   (`appInstalled: NO` all day) — the OS refuses every send in that
///   state while the watch still shows "iPhone reachable". Surfacing it
///   turns a 5-minute mystery into a 2-second diagnosis.
/// - Start commands ride sendMessage (fast) + applicationContext
///   (latest-only state, delivered on watch activation) — NOT
///   transferUserInfo, whose persistent queue can replay a stale start
///   hours later. Outstanding transfers are purged at activation.
/// - Every envelope carries the sender build + sentAt so the receiver
///   can detect dev-deploy drift and drop stale commands.
///
/// Concurrency notes:
/// - Class is `@MainActor` so SwiftUI can read its `@Observable` state.
/// - Delegate methods are `nonisolated` because WatchConnectivity invokes
///   them on a background queue. They capture values into locals before
///   hopping to MainActor for state mutation and ingest.
@Observable
@MainActor
final class PhoneSession: NSObject {
    static let shared = PhoneSession()

    var isReachable: Bool = false
    var isPaired: Bool = false
    /// Whether the iPhone's pairing registry believes the AARC watch app
    /// is installed. When false, iOS refuses ALL WatchConnectivity sends
    /// ("counterpart app not installed") — the exact 2026-06-10 failure.
    /// Fix is outside the app: reboot the watch (registry re-sync) or
    /// reinstall the watch app.
    var isWatchAppInstalled: Bool = false
    var activationState: WCSessionActivationState = .notActivated
    var lastInboundText: String?

    /// Build number reported by the watch in its envelopes. nil until
    /// the first inbound message from the current watch build.
    var counterpartBuild: String?
    /// True when the watch's build differs from ours — dev-deploy drift.
    /// Surfaced as a banner; drift makes schema changes silently
    /// undecodable, which is one of the two handover failure classes.
    var buildMismatch: Bool = false
    /// Set when an inbound payload fails to decode — with drift this is
    /// the visible symptom of a schema mismatch.
    var lastDecodeFailureAt: Date?

    private let session: WCSession?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let log = Logger(subsystem: "club.aarun.AARC", category: "WC")

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else {
            log.error("[phone] WCSession unsupported on this device")
            return
        }
        session.delegate = self
        session.activate()
        log.info("[phone] activate() requested")
    }

    /// Await activation for up to `timeout` seconds. Closes the cold-launch
    /// race where Start is tapped before the `.task` activation completed —
    /// previously `sendStateEvent` silently dropped the command.
    func ensureActivated(timeout: TimeInterval = 2.0) async -> Bool {
        if activationState == .activated { return true }
        activate()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activationState == .activated { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log.error("[phone] ensureActivated timed out — state=\(self.activationState.rawValue)")
        return activationState == .activated
    }

    func sendHello(text: String = "hello from phone") {
        guard let session,
              session.activationState == .activated,
              session.isReachable else { return }
        let message = WCMessage.hello(text: text)
        guard let data = try? encoder.encode(message) else { return }
        session.sendMessageData(data, replyHandler: nil) { _ in }
    }

    // MARK: - Envelope

    /// Wrap an encoded WCMessage with sender build + timestamp. The extra
    /// keys are ignored by older builds (wire-compatible) and let the
    /// receiver detect drift + drop stale commands.
    private func envelope(_ data: Data) -> [String: Any] {
        [
            Self.userInfoMessageKey: data,
            Self.buildKey: AppVersion.build,
            Self.sentAtKey: Date().timeIntervalSince1970,
        ]
    }

    // MARK: - Outbound

    /// Send a state event to the watch (scriptReady / scriptFailed /
    /// endWorkout / cancelStart). Two-tier: sendMessage when reachable
    /// (instant) + transferUserInfo (queued for next watch launch).
    /// Start commands use `sendStartCommand` instead — their staleness
    /// semantics are different.
    func sendStateEvent(_ event: WCMessage) {
        guard let session else { return }
        guard session.activationState == .activated else {
            log.error("[phone] sendStateEvent dropped — not activated (state=\(session.activationState.rawValue))")
            return
        }
        guard let data = try? encoder.encode(event) else {
            log.error("[phone] sendStateEvent encode FAILED")
            return
        }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { [log] error in
                log.error("[phone] sendMessageData failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        session.transferUserInfo(envelope(data))
        log.info("[phone] state event sent (reachable=\(session.isReachable))")
    }

    /// Send the run-start command. Rides BOTH:
    ///   1. sendMessage — instant when the watch app is reachable.
    ///   2. updateApplicationContext — latest-only state delivered when
    ///      the watch app next activates (incl. the startWatchApp launch).
    /// Deliberately NOT transferUserInfo: its persistent queue can replay
    /// a stale start command hours later. applicationContext is
    /// overwritten by every newer write, so the watch only ever sees the
    /// most recent intent — and the receiver still TTL-checks sentAt.
    /// Each call writes a fresh sentAt, so retries are never suppressed
    /// by WC's identical-dictionary optimization.
    func sendStartCommand(_ event: WCMessage) {
        guard let session else { return }
        guard session.activationState == .activated else {
            log.error("[phone] sendStartCommand dropped — not activated")
            return
        }
        guard let data = try? encoder.encode(event) else {
            log.error("[phone] sendStartCommand encode FAILED")
            return
        }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { [log] error in
                log.error("[phone] start sendMessageData failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try session.updateApplicationContext(envelope(data))
            log.info("[phone] start command sent (reachable=\(session.isReachable), appInstalled=\(session.isWatchAppInstalled))")
        } catch {
            log.error("[phone] updateApplicationContext failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancel any stale queued transfers. Called once per activation —
    /// drains the historical transferUserInfo backlog so a start command
    /// queued by an old build can't replay into a fresh session.
    private func purgeStaleTransfers() {
        guard let session else { return }
        let outstanding = session.outstandingUserInfoTransfers
        guard !outstanding.isEmpty else { return }
        log.info("[phone] purging \(outstanding.count) outstanding userInfo transfers")
        for transfer in outstanding { transfer.cancel() }
    }

    // MARK: - Inbound routing

    /// Decode + route a WCMessage inbound from the watch.
    private func route(_ message: WCMessage) {
        switch message {
        case .hello(let text):
            self.lastInboundText = text

        case .liveMetrics(let metrics):
            // While a mirrored session is live, metrics arrive over the
            // HealthKit mirroring channel — skip the WC copy so each
            // tick isn't ingested twice. WC resumes the moment the
            // mirror drops (receiver clears itself on disconnect).
            guard !MirroringReceiver.shared.isMirroring else { return }
            LiveMetricsConsumer.shared.ingest(metrics)

        case .startAck(let runId):
            RunOrchestrator.shared.watchAcknowledgedStart(runId: runId)

        case .startDeclined(let runId, let reason):
            RunOrchestrator.shared.watchDeclinedStart(runId: runId, reason: reason)

        case .workoutStarted(let runId, let startedAt):
            LiveMetricsConsumer.shared.ingestStarted(runId: runId, startedAt: startedAt)

        case .workoutPaused:
            LiveMetricsConsumer.shared.ingestPaused()

        case .workoutResumed:
            LiveMetricsConsumer.shared.ingestResumed()

        case .workoutEnded(let workoutUUID):
            LiveMetricsConsumer.shared.ingestEnded(workoutUUID: workoutUUID)

        case .prepareWorkout(let runId, let runType, let personalityId):
            // Watch user just hit Start. Stash run type so the Live
            // Activity can render the right label, then generate a
            // script for them.
            LiveMetricsConsumer.shared.pendingRunType = runType
            LiveMetricsConsumer.shared.pendingPersonalityId = personalityId
            Task {
                await RunOrchestrator.shared.handlePrepareFromWatch(
                    runId: runId,
                    runType: runType,
                    personalityId: personalityId
                )
            }

        // Outbound-only on phone side; ignore if echoed somehow.
        case .startWorkout, .cancelStart, .endWorkout, .hapticCue,
             .companionMessageDispatched, .scriptReady, .scriptFailed:
            break
        }
    }

    /// Typed, Sendable projection of an envelope dictionary — extracted
    /// on the delegate's queue so no [String: Any] crosses actor lines
    /// (Swift 6 strict concurrency).
    struct Envelope: Sendable {
        let data: Data?
        let build: String?
        let sentAt: TimeInterval?
    }

    nonisolated static func extract(_ dict: [String: Any]) -> Envelope {
        Envelope(
            data: dict[userInfoMessageKey] as? Data,
            build: dict[buildKey] as? String,
            sentAt: dict[sentAtKey] as? TimeInterval
        )
    }

    /// Shared decode + envelope-metadata handling for the queued paths.
    private func consume(_ envelope: Envelope, via channel: String) {
        if let build = envelope.build {
            counterpartBuild = build
            // Compare only the build-number prefix: CFBundleVersion is
            // stamped "<build>.<HHMMSS>" and the HHMMSS differs between
            // targets even within the same deploy.
            let mine = AppVersion.build.split(separator: ".").first ?? ""
            let theirs = build.split(separator: ".").first ?? ""
            buildMismatch = (mine != theirs)
            if buildMismatch {
                log.error("[phone] BUILD MISMATCH — watch=\(build, privacy: .public) phone=\(AppVersion.build, privacy: .public)")
            }
        }
        guard let data = envelope.data else { return }
        guard let message = try? decoder.decode(WCMessage.self, from: data) else {
            lastDecodeFailureAt = .now
            log.error("[phone] decode FAILED via \(channel, privacy: .public) — likely build drift")
            return
        }
        route(message)
    }
}

extension PhoneSession: @preconcurrency WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let isPaired = session.isPaired
        let isReachable = session.isReachable
        let installed = session.isWatchAppInstalled
        let errText = error?.localizedDescription
        Task { @MainActor in
            self.activationState = activationState
            self.isPaired = isPaired
            self.isReachable = isReachable
            self.isWatchAppInstalled = installed
            if let errText {
                self.log.error("[phone] activation error: \(errText, privacy: .public)")
            }
            self.log.info("[phone] activated state=\(activationState.rawValue) paired=\(isPaired) reachable=\(isReachable) appInstalled=\(installed)")
            self.purgeStaleTransfers()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.log.info("[phone] session became inactive") }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
        Task { @MainActor in self.log.info("[phone] session deactivated — re-activating") }
    }

    /// Pairing/installation state changed — the registry-drift detector.
    /// `isWatchAppInstalled` flipping to false mid-session is exactly the
    /// state that killed the 2026-06-10 morning session.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let isPaired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isPaired = isPaired
            self.isWatchAppInstalled = installed
            self.log.info("[phone] watch state changed paired=\(isPaired) appInstalled=\(installed)")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isReachable = isReachable
            self.log.info("[phone] reachability → \(isReachable)")
            // Self-heal: the moment the link comes back, re-send any
            // pending unacknowledged start command.
            if isReachable {
                RunOrchestrator.shared.linkBecameReachable()
            }
        }
    }

    /// Live-metrics path (1 Hz, best-effort).
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            guard let message = try? self.decoder.decode(WCMessage.self, from: messageData) else {
                self.lastDecodeFailureAt = .now
                self.log.error("[phone] decode FAILED via sendMessage — likely build drift")
                return
            }
            self.route(message)
        }
    }

    /// State-event path (queued, guaranteed delivery).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let envelope = Self.extract(userInfo)
        Task { @MainActor in
            self.consume(envelope, via: "userInfo")
        }
    }

    /// Latest-state path (applicationContext).
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let envelope = Self.extract(applicationContext)
        Task { @MainActor in
            self.consume(envelope, via: "appContext")
        }
    }

    /// Transfer outcomes — previously invisible.
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let errText = error?.localizedDescription
        Task { @MainActor in
            if let errText {
                self.log.error("[phone] userInfo transfer FAILED: \(errText, privacy: .public)")
            } else {
                self.log.info("[phone] userInfo transfer delivered")
            }
        }
    }

    /// Key shared with the watch side for envelope wrapping.
    nonisolated static let userInfoMessageKey = "wc.message"
    nonisolated static let buildKey = "wc.build"
    nonisolated static let sentAtKey = "wc.sentAt"
}
