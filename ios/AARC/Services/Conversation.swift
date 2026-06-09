import Foundation
import Observation
import OSLog
import AARCKit

/// Orchestrates the second voice — Jessica. When Ricky (ScriptEngine or
/// ContextualCoach) speaks a line, the dispatcher calls `rickySpoke`. This
/// asks the Director whether there's room in the timeline, and if so
/// generates Jessica's reaction via `/react-line` and enqueues it right
/// behind his line at the SAME priority + a shared `segmentId`, so the
/// two play as an atomic two-hander.
///
/// Additive by design: the primary voice's generation and dispatch are
/// unchanged. If Jessica is disabled, there's no room, or the line is itself
/// a Jessica reply, this is a no-op.
@MainActor
@Observable
final class Conversation {
    static let shared = Conversation()

    private static let kEnabled = "aarc.voice.jessicaEnabled"

    /// Master switch for the second voice. Persisted; defaults on.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.kEnabled) }
    }

    // Diagnostic state.
    private(set) var lastReaction: String?
    private(set) var lastError: String?

    private var inFlight: Task<Void, Never>?
    private let log = Logger(subsystem: "club.aarun.AARC", category: "Conversation")

    init() {
        let store = UserDefaults.standard
        if store.object(forKey: Self.kEnabled) == nil {
            store.set(true, forKey: Self.kEnabled)
        }
        self.enabled = store.bool(forKey: Self.kEnabled)
    }

    /// Called right after Ricky speaks a line. `segmentId` must match the
    /// one the caller tagged Ricky's line with, so the queue can keep the
    /// pair atomic. No-op if Jessica is disabled, the Director says there's
    /// no room, or `source` is itself a Jessica line (never react to a
    /// reaction — that would loop).
    func rickySpoke(
        text: String,
        source: String,
        priority: VoicePriority,
        segmentId: UUID,
        metrics: LiveMetrics
    ) {
        guard enabled else { return }
        guard !source.hasPrefix("jessica") else { return }
        guard RunDirector.shared.hasRoomForExchange else {
            log.info("Jessica skipped — no room before next must-play")
            return
        }

        let plan = ScriptPreviewStore.shared.currentPlan
        let runType = LiveMetricsConsumer.shared.pendingRunType
        // Project forward too — Jessica plays after Ricky, so if she quotes
        // a number it should match where the runner is by then.
        let projected = RunDirector.shared.projected(
            distance: metrics.distanceMeters,
            elapsed: metrics.elapsed
        )
        let context = AIClient.ReactLineContext(
            elapsedSeconds: projected.elapsed,
            distanceMeters: projected.distance,
            currentHR: metrics.currentHeartRate,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            planKind: plan.kind.rawValue,
            runType: runType.rawValue
        )
        let recent = ScriptEngine.shared.recentDispatchedLines
        let notes = PersonalContextStore.shared.bullets
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: "jessica")
        let request = AIClient.ReactLineRequest(
            personalityId: "jessica",
            partnerLine: text,
            partnerSource: source,
            runContext: context,
            recentDispatched: recent.isEmpty ? nil : recent,
            personalNotes: notes.isEmpty ? nil : notes,
            likedLineExamples: liked.isEmpty ? nil : liked
        )

        log.info("Jessica reacting to \(source, privacy: .public)")
        // Only one reaction in flight; a fresh Ricky line supersedes a
        // not-yet-spoken reaction to the previous one.
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = nil }
            do {
                let result = try await AIClient.shared.reactLine(request)
                guard !Task.isCancelled, ScriptEngine.shared.isActive else { return }
                Speaker.shared.speak(
                    result.text,
                    priority: priority,
                    source: "jessica:react",
                    expiresAfter: 75,
                    voiceId: RemoteTTS.jessicaVoiceId,
                    segmentId: segmentId
                )
                self.lastReaction = result.text
                self.lastError = nil
            } catch {
                if Task.isCancelled { return }
                self.lastError = error.localizedDescription
                self.log.error("Jessica reactLine error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Cancel any in-flight reaction. Called at run end so a late reply
    /// can't speak after the pipeline is torn down.
    func stop() {
        inFlight?.cancel()
        inFlight = nil
    }
}
