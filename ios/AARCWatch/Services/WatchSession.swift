import Foundation
import WatchConnectivity
import WatchKit
import OSLog
import AARCKit

/// watchOS-side wrapper around `WCSession`. Outbound channel for
/// `LiveMetrics` (1 Hz, best-effort) and workout state events (queued,
/// guaranteed). Inbound: start/cancel/end commands + script events from
/// the phone, now via ALL THREE transports (sendMessage, userInfo queue,
/// applicationContext) with dedupe + staleness gating, so a delivered
/// command is honored exactly once and a stale replay never ghost-starts
/// a run.
@Observable
@MainActor
final class WatchSession: NSObject {
    static let shared = WatchSession()

    var isReachable: Bool = false
    var activationState: WCSessionActivationState = .notActivated
    var lastInboundText: String?

    /// The coach line currently on screen (mirrored from the phone). nil = none.
    var currentCoachLine: CoachLine?
    /// Line ids the runner has hearted this session (so the heart stays filled).
    var heartedLineIds: Set<UUID> = []

    /// Build number reported by the phone in its envelopes; drives the
    /// drift banner on the idle screen.
    var counterpartBuild: String?
    var buildMismatch: Bool = false

    private let session: WCSession?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let log = Logger(subsystem: "club.aarun.AARC", category: "WC")

    /// Shared envelope keys with the iPhone side.
    nonisolated static let userInfoMessageKey = "wc.message"
    nonisolated static let buildKey = "wc.build"
    nonisolated static let sentAtKey = "wc.sentAt"

    /// Start commands older than this are stale — the phone has long
    /// since timed out and offered phone-only. Executing one would start
    /// a ghost run (and possibly double-track). Dropped with a log.
    private static let startCommandTTL: TimeInterval = 30

    /// Recently handled start runIds (persisted ring) — a command that
    /// arrives via two transports executes once.
    private static let handledStartsKey = "aarc.wc.handledStartRunIds"
    private var handledStartRunIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.handledStartsKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(50)), forKey: Self.handledStartsKey) }
    }

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else {
            log.error("[watch] WCSession unsupported")
            return
        }
        session.delegate = self
        session.activate()
        log.info("[watch] activate() requested")
    }

    /// Re-check the last applicationContext for a pending start command.
    /// Called on every foreground — covers the case where the activation
    /// snapshot raced or the context landed while neither delegate fired.
    /// Skips fossils up-front (the slot persists forever), so repeated
    /// sweeps don't spam stale-drop logs/breadcrumbs; TTL + the
    /// handled-runId ledger still backstop anything that slips through.
    func reconsumePendingContext() {
        guard let session, session.activationState == .activated else { return }
        let pending = Self.extract(session.receivedApplicationContext)
        guard pending.data != nil else { return }
        guard let sentAt = pending.sentAt,
              Date().timeIntervalSince1970 - sentAt <= Self.startCommandTTL else { return }
        consume(pending, via: "appContext@foreground")
    }

    /// Publish a presence handshake (build + fresh timestamp) into the
    /// watch→phone applicationContext slot at every launch, so the phone
    /// always has CURRENT watch-build info for its drift banner.
    private func publishPresenceContext() {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext([
                Self.buildKey: AppVersion.build,
                Self.sentAtKey: Date().timeIntervalSince1970,
            ])
            log.info("[watch] presence context published (build \(AppVersion.build, privacy: .public))")
        } catch {
            log.error("[watch] presence context failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Outbound

    private func envelope(_ data: Data) -> [String: Any] {
        [
            Self.userInfoMessageKey: data,
            Self.buildKey: AppVersion.build,
            Self.sentAtKey: Date().timeIntervalSince1970,
        ]
    }

    /// 1 Hz live metrics. Best-effort — drops if phone unreachable.
    /// The watch itself remains the source of truth via HealthKit, so
    /// drops are acceptable.
    func sendLiveMetrics(_ metrics: LiveMetrics) {
        guard let session,
              session.activationState == .activated,
              session.isReachable else { return }
        let message = WCMessage.liveMetrics(metrics)
        guard let data = try? encoder.encode(message) else { return }
        // @Sendable is load-bearing: WC fires this on its own background
        // queue; an inferred-@MainActor closure crashes on first failure.
        let onError: @Sendable (any Error) -> Void = { _ in
            // Silent on failure — next tick will retry; nothing to recover.
        }
        session.sendMessageData(data, replyHandler: nil, errorHandler: onError)
    }

    /// Workout state events: workoutStarted / paused / resumed / ended /
    /// startAck / startDeclined / prepareWorkout. Two-tier: sendMessage
    /// when reachable (instant — cuts the prepare round-trip from
    /// queue-whim latency to ~immediate) + transferUserInfo (queued for
    /// when the phone wakes).
    func sendStateEvent(_ event: WCMessage) {
        guard let session else { return }
        guard session.activationState == .activated else {
            log.error("[watch] sendStateEvent dropped — not activated")
            return
        }
        guard let data = try? encoder.encode(event) else {
            log.error("[watch] sendStateEvent encode FAILED")
            return
        }
        if session.isReachable {
            // @Sendable: WC calls this off-main; Logger is Sendable.
            let onError: @Sendable (any Error) -> Void = { [log] error in
                log.error("[watch] sendMessageData failed: \(error.localizedDescription, privacy: .public)")
            }
            session.sendMessageData(data, replyHandler: nil, errorHandler: onError)
        }
        session.transferUserInfo(envelope(data))
        log.info("[watch] state event sent (reachable=\(session.isReachable))")
    }
}

extension WatchSession: @preconcurrency WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let isReachable = session.isReachable
        let errText = error?.localizedDescription
        // Snapshot any start command the phone wrote to applicationContext
        // while we weren't running — this is how a startWatchApp launch
        // (or plain cold launch) picks up its parameters. Extract the
        // typed (Sendable) fields here; [String: Any] can't cross the
        // MainActor hop under strict concurrency.
        let pending = Self.extract(session.receivedApplicationContext)
        Task { @MainActor in
            self.activationState = activationState
            self.isReachable = isReachable
            if let errText {
                self.log.error("[watch] activation error: \(errText, privacy: .public)")
            }
            self.log.info("[watch] activated state=\(activationState.rawValue) reachable=\(isReachable)")
            self.publishPresenceContext()
            if pending.data != nil || pending.build != nil {
                self.consume(pending, via: "appContext@activation")
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isReachable = isReachable
            self.log.info("[watch] reachability → \(isReachable)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in
            guard let message = try? self.decoder.decode(WCMessage.self, from: messageData) else {
                self.log.error("[watch] decode FAILED via sendMessage — likely build drift")
                return
            }
            // Live path: delivery is immediate, so freshness is implied.
            self.route(message, sentAt: nil, isLive: true)
        }
    }

    /// State events from the phone arrive via transferUserInfo.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let envelope = Self.extract(userInfo)
        Task { @MainActor in
            self.consume(envelope, via: "userInfo")
        }
    }

    /// Latest-state path — the start command's guaranteed channel.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let envelope = Self.extract(applicationContext)
        Task { @MainActor in
            self.consume(envelope, via: "appContext")
        }
    }

    /// Typed, Sendable projection of an envelope dictionary — extracted
    /// on the delegate's queue so no [String: Any] crosses actor lines.
    struct Envelope: Sendable {
        let data: Data?
        let build: String?
        let sentAt: TimeInterval?
    }

    nonisolated private static func extract(_ dict: [String: Any]) -> Envelope {
        Envelope(
            data: dict[userInfoMessageKey] as? Data,
            build: dict[buildKey] as? String,
            sentAt: dict[sentAtKey] as? TimeInterval
        )
    }

    /// Envelopes older than this can't update the drift detector: the
    /// persistent applicationContext re-delivers the LAST-ever write on
    /// every activation/foreground — yesterday's envelope from
    /// yesterday's phone build must not masquerade as its current
    /// version (field bug: watch showed "phone 72 ≠ watch 73" when both
    /// were on 73, sourced from a fossil start command in the slot).
    private static let buildInfoFreshness: TimeInterval = 120

    @MainActor
    private func consume(_ envelope: Envelope, via channel: String) {
        let isFresh = envelope.sentAt.map { Date().timeIntervalSince1970 - $0 <= Self.buildInfoFreshness } ?? false
        if let build = envelope.build, isFresh {
            counterpartBuild = build
            // Compare only the build-number prefix: CFBundleVersion is
            // stamped "<build>.<HHMMSS>" and the HHMMSS differs between
            // targets even within the same deploy.
            let mine = AppVersion.build.split(separator: ".").first ?? ""
            let theirs = build.split(separator: ".").first ?? ""
            buildMismatch = (mine != theirs)
            if buildMismatch {
                log.error("[watch] BUILD MISMATCH — phone=\(build, privacy: .public) watch=\(AppVersion.build, privacy: .public)")
            }
        }
        guard let data = envelope.data else { return }
        guard let message = try? decoder.decode(WCMessage.self, from: data) else {
            log.error("[watch] decode FAILED via \(channel, privacy: .public) — likely build drift")
            return
        }
        route(message, sentAt: envelope.sentAt.map(Date.init(timeIntervalSince1970:)), isLive: false)
    }

    @MainActor
    private func route(_ message: WCMessage, sentAt: Date?, isLive: Bool) {
        switch message {
        case .hello(let text):
            self.lastInboundText = text

        case .scriptReady:
            WorkoutSessionHost.shared.onScriptReady()

        case .scriptFailed(let reason):
            WorkoutSessionHost.shared.onScriptFailed(reason: reason)

        case .startWorkout(let runId, let runType, let personalityId):
            handleStartCommand(runId: runId, runType: runType, personalityId: personalityId,
                               sentAt: sentAt, isLive: isLive)

        case .cancelStart(let runId):
            // Unburn the ledger so a later re-dispatch of this id isn't
            // swallowed as a duplicate after an explicit cancel.
            handledStartRunIds.removeAll { $0 == runId.uuidString }
            WorkoutSessionHost.shared.cancelRemoteStart(runId: runId)

        case .endWorkout:
            // Phone is asking us to end (e.g., bigger UI on the phone).
            Task { _ = await WorkoutSessionHost.shared.endRun() }

        case .coachLine(let id, let text, let who):
            // The current coach line, for the watch's Coach page.
            if text.isEmpty {
                currentCoachLine = nil
            } else {
                currentCoachLine = CoachLine(id: id, text: text, who: who, receivedAt: Date())
            }

        // Inbound only from the phone-initiation path; ignore all
        // outbound message cases that should never come back to us.
        case .hapticCue, .companionMessageDispatched,
             .prepareWorkout, .workoutStarted, .workoutPaused,
             .workoutResumed, .workoutEnded, .liveMetrics,
             .heartLine, .startAck, .startDeclined:
            break
        }
    }

    // MARK: - Coach line (heart-from-watch)

    struct CoachLine: Equatable {
        let id: UUID
        let text: String
        let who: String        // "ricky" | "jessica"
        let receivedAt: Date
    }

    /// Send a heart for the current line back to the phone (records the like).
    func heartCurrentLine() {
        guard let line = currentCoachLine, !heartedLineIds.contains(line.id) else { return }
        heartedLineIds.insert(line.id)
        sendStateEvent(.heartLine(id: line.id, text: line.text, who: line.who))
    }

    /// Phone-initiated start, hardened:
    /// 1. TTL — a stale command (phone gave up long ago) is dropped.
    /// 2. Dedupe — multi-transport copies execute once.
    /// 3. Phase guard — never hijacks an in-progress run; declines so
    ///    the phone falls back immediately instead of timing out.
    /// 4. Early ACK — the phone learns within ~1s that we're on it.
    @MainActor
    private func handleStartCommand(runId: UUID, runType: RunType, personalityId: String, sentAt: Date?, isLive: Bool) {
        // Staleness. Store-and-forward channels (userInfo/appContext —
        // incl. the activation snapshot, which re-delivers the last
        // context on EVERY launch forever) must carry a fresh sentAt;
        // a missing one means a pre-envelope phone build, and treating
        // it as fresh would ghost-start runs on every cold launch. Only
        // the live sendMessage path may omit it (delivery is immediate).
        if isLive == false {
            guard let sentAt, Date().timeIntervalSince(sentAt) <= Self.startCommandTTL else {
                let age = sentAt.map { "\(Int(Date().timeIntervalSince($0)))s old" } ?? "no sentAt"
                log.error("[watch] DROPPED stale start (\(age, privacy: .public))")
                WatchBreadcrumbs.shared.drop("start cmd stale (\(age))")
                return
            }
        }
        if handledStartRunIds.contains(runId.uuidString) {
            log.info("[watch] duplicate start \(runId.uuidString.prefix(8), privacy: .public) — already handled")
            return
        }
        let phase = WorkoutSessionHost.shared.phase
        guard phase == .idle || phase == .ended || phase == .error else {
            log.error("[watch] start declined — busy (phase=\(phase.rawValue, privacy: .public))")
            WatchBreadcrumbs.shared.drop("start declined: busy \(phase.rawValue)")
            sendStateEvent(.startDeclined(runId: runId, reason: "watch is busy (\(phase.rawValue))"))
            return
        }
        handledStartRunIds.append(runId.uuidString)
        sendStateEvent(.startAck(runId: runId))
        log.info("[watch] start accepted \(runId.uuidString.prefix(8), privacy: .public)")
        WatchBreadcrumbs.shared.drop("start cmd accepted")

        // No haptic here: a background launch silently drops it anyway,
        // and the host plays the proper .start haptic the moment the
        // session is actually running (NRC-style — no jarring buzz).
        Task { @MainActor in
            await WorkoutSessionHost.shared.beginRun(
                runType: runType,
                runId: runId,
                personalityId: personalityId,
                prepareScriptOnPhone: false,
                skipCountdown: true
            )
            // If the start failed (e.g. HealthKit not authorized on a
            // background launch), tell the phone NOW so it offers
            // phone-only immediately instead of waiting out its timer.
            if WorkoutSessionHost.shared.phase == .error {
                self.handledStartRunIds.removeAll { $0 == runId.uuidString }
                self.sendStateEvent(.startDeclined(
                    runId: runId,
                    reason: WorkoutSessionHost.shared.lastError ?? "start failed"
                ))
            }
        }
    }
}
