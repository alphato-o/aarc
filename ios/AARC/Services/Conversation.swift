import Foundation
import Observation
import OSLog
import AARCKit

/// Orchestrates the second voice — Pippa. When Ricky (ScriptEngine or
/// ContextualCoach) speaks a line, the dispatcher calls `rickySpoke`. This
/// asks the Director whether there's room in the timeline, and if so
/// generates Pippa's reaction via `/react-line` and enqueues it right
/// behind his line at the SAME priority + a shared `segmentId`, so the
/// two play as an atomic two-hander.
///
/// Additive by design: the primary voice's generation and dispatch are
/// unchanged. If Pippa is disabled, there's no room, or the line is itself
/// a Pippa reply, this is a no-op.
@MainActor
@Observable
final class Conversation {
    static let shared = Conversation()

    private static let kEnabled = "aarc.voice.pippaEnabled"

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
    /// pair atomic. No-op if Pippa is disabled, the Director says there's
    /// no room, or `source` is itself a Pippa line (never react to a
    /// reaction — that would loop).
    func rickySpoke(
        text: String,
        source: String,
        priority: VoicePriority,
        segmentId: UUID,
        metrics: LiveMetrics
    ) {
        guard enabled else { return }
        guard !source.hasPrefix("pippa") else { return }
        guard RunDirector.shared.hasRoomForExchange else {
            log.info("Pippa skipped — no room before next must-play")
            return
        }

        let plan = ScriptPreviewStore.shared.currentPlan
        let runType = LiveMetricsConsumer.shared.pendingRunType
        let context = AIClient.ReactLineContext(
            elapsedSeconds: metrics.elapsed,
            distanceMeters: metrics.distanceMeters,
            currentHR: metrics.currentHeartRate,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            planKind: plan.kind.rawValue,
            runType: runType.rawValue
        )
        let recent = ScriptEngine.shared.recentDispatchedLines
        let notes = PersonalContextStore.shared.bullets
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: "pippa")
        let request = AIClient.ReactLineRequest(
            personalityId: "pippa",
            partnerLine: text,
            partnerSource: source,
            runContext: context,
            recentDispatched: recent.isEmpty ? nil : recent,
            personalNotes: notes.isEmpty ? nil : notes,
            likedLineExamples: liked.isEmpty ? nil : liked
        )

        log.info("Pippa reacting to \(source, privacy: .public)")
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
                    source: "pippa:react",
                    expiresAfter: 75,
                    voiceId: RemoteTTS.pippaVoiceId,
                    segmentId: segmentId
                )
                self.lastReaction = result.text
                self.lastError = nil
            } catch {
                if Task.isCancelled { return }
                self.lastError = error.localizedDescription
                self.log.error("Pippa reactLine error: \(error.localizedDescription, privacy: .public)")
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
