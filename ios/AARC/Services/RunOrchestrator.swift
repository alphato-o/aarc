import Foundation
import Observation
import AARCKit

/// Coordinates the "user wants to start a run" flow on the phone,
/// regardless of whether the trigger came from the iPhone (its own
/// Start button) or the Apple Watch (sent prepareWorkout to us).
///
/// Both paths converge on:
/// 1. Generate a Roast Coach script via AIClient (talks to proxy).
///    Generation routinely takes 30-50s, so we pre-generate
///    speculatively as soon as the user lands on RunHomeView and
///    every time they change the plan / personality. When they
///    finally tap Start, the in-flight task is awaited if still
///    running, or the cached result is used instantly.
/// 2. Cache the script in ScriptPreviewStore (which ScriptEngine reads
///    at the moment the watch's HKWorkoutSession actually fires
///    workoutStarted).
/// 3. Pre-fetch the first few lines' TTS audio in the background.
/// 4. Tell the watch what to do next:
///      - phone-initiated: send startWorkout (watch goes to countdown).
///      - watch-initiated: send scriptReady (watch transitions from
///        preparing → countdown).
@Observable
@MainActor
final class RunOrchestrator {
    static let shared = RunOrchestrator()

    enum Phase: String, Sendable {
        case idle
        case generating         // foreground generation (user is waiting)
        case sentToWatch        // phone-initiated: handed off to watch
        case error
    }

    private(set) var phase: Phase = .idle
    var lastError: String?

    /// True while a speculative pre-generation is in flight. UI binds
    /// to this to show a faint "Coach pre-loading…" hint.
    private(set) var isPreGenerating: Bool = false

    /// Last-completed pre-generation result. Cleared when consumed by a
    /// Start tap, or when the plan/personality changes.
    private var preGenTask: Task<GeneratedScript, Error>?
    private var preGenKey: String?

    /// Phone tapped Start in PHONE-ONLY mode. Phone tracks the run via
    /// CoreLocation + HKWorkoutBuilder (no watch involvement). Same
    /// downstream pipeline (ScriptEngine, ContextualCoach, Live Activity)
    /// because PhoneWorkoutSession publishes the same LiveMetrics shape.
    func startPhoneOnly(runType: RunType, personalityId: String = "roast_coach") async {
        guard phase != .generating else { return }
        phase = .generating
        lastError = nil

        let plan = ScriptPreviewStore.shared.currentPlan
        let key = makeKey(plan: plan, personalityId: personalityId)
        let runId = UUID()

        do {
            let script = try await resolveScript(plan: plan, runType: runType, personalityId: personalityId, key: key)
            ScriptPreviewStore.shared.latest = script
            prefetchEarlyLines(script: script)

            try await PhoneWorkoutSession.shared.start(
                runType: runType,
                runId: runId,
                personalityId: personalityId
            )
            // No watch involvement — no startWorkout WC message, no
            // wrist-cue notification. The phone is tracking, done.
            phase = .idle
        } catch {
            phase = .error
            lastError = error.localizedDescription
        }
    }

    /// Phone tapped Start. Use the pre-gen result if it's for the
    /// current plan/personality, else generate fresh.
    func startFromPhone(runType: RunType, personalityId: String = "roast_coach") async {
        guard phase != .generating else { return }
        phase = .generating
        lastError = nil

        // Stash so the Live Activity (started later from ingestStarted)
        // can render the right label.
        LiveMetricsConsumer.shared.pendingRunType = runType
        LiveMetricsConsumer.shared.pendingPersonalityId = personalityId

        let plan = ScriptPreviewStore.shared.currentPlan
        let key = makeKey(plan: plan, personalityId: personalityId)
        let runId = UUID()

        do {
            let script = try await resolveScript(plan: plan, runType: runType, personalityId: personalityId, key: key)
            ScriptPreviewStore.shared.latest = script
            prefetchEarlyLines(script: script)

            PhoneSession.shared.sendStateEvent(
                .startWorkout(runId: runId, runType: runType, personalityId: personalityId)
            )
            // Buzz the wrist + leave a tappable card on the watch (via
            // iOS->Apple Watch notification mirroring) so the user
            // doesn't have to manually launch the watch app. Tapping
            // the watch notification launches AARCWatch, which consumes
            // the queued startWorkout via WatchConnectivity.
            Task { @MainActor in
                await PhoneNotificationCenter.shared.scheduleStartCue()
            }
            phase = .sentToWatch
        } catch {
            phase = .error
            lastError = error.localizedDescription
        }
    }

    /// Watch sent prepareWorkout. Same resolve-from-cache-or-generate
    /// path, then reply over WC.
    func handlePrepareFromWatch(
        runId: UUID,
        runType: RunType,
        personalityId: String
    ) async {
        phase = .generating
        lastError = nil

        let plan = ScriptPreviewStore.shared.currentPlan
        let key = makeKey(plan: plan, personalityId: personalityId)

        do {
            let script = try await resolveScript(plan: plan, runType: runType, personalityId: personalityId, key: key)
            ScriptPreviewStore.shared.latest = script
            prefetchEarlyLines(script: script)
            PhoneSession.shared.sendStateEvent(.scriptReady(scriptId: script.scriptId))
            phase = .idle
        } catch {
            phase = .error
            lastError = error.localizedDescription
            PhoneSession.shared.sendStateEvent(
                .scriptFailed(reason: error.localizedDescription)
            )
        }
    }

    /// Kick off a speculative generation in the background. Idempotent
    /// for the same plan/personality — won't re-fire if a task already
    /// matches. Cancels and replaces if the key changes.
    /// Called by RunHomeView on appear and on plan/personality change.
    func schedulePreGenerate(personalityId: String = "roast_coach") {
        let plan = ScriptPreviewStore.shared.currentPlan
        let key = makeKey(plan: plan, personalityId: personalityId)

        if preGenKey == key, preGenTask != nil { return }
        preGenTask?.cancel()
        preGenKey = key
        isPreGenerating = true

        // Pre-gen uses .treadmill as the runType — the actual line
        // content is essentially runtype-agnostic, so we cache once
        // and reuse for either Start button on RunHomeView.
        preGenTask = Task { @MainActor [weak self] in
            defer { self?.isPreGenerating = false }
            guard let self else {
                throw CancellationError()
            }
            return try await self.generate(
                plan: plan,
                runType: .treadmill,
                personalityId: personalityId
            )
        }
    }

    /// Reset after dismissing an error so the user can retry.
    func clearError() {
        if phase == .error {
            phase = .idle
            lastError = nil
        }
    }

    // MARK: - Private

    /// Either await an in-flight matching pre-gen Task, or kick a fresh
    /// generation. Caller is already in `.generating` phase.
    private func resolveScript(
        plan: RunPlan,
        runType: RunType,
        personalityId: String,
        key: String
    ) async throws -> GeneratedScript {
        if preGenKey == key, let task = preGenTask {
            // Await whatever the background already started — could be
            // already-complete (instant) or still running.
            do {
                let script = try await task.value
                preGenTask = nil
                preGenKey = nil
                return script
            } catch {
                // Pre-gen failed; fall through to fresh attempt.
                preGenTask = nil
                preGenKey = nil
            }
        }
        return try await generate(plan: plan, runType: runType, personalityId: personalityId)
    }

    private func generate(
        plan: RunPlan,
        runType: RunType,
        personalityId: String
    ) async throws -> GeneratedScript {
        let payload = AIClient.ScriptPlan.from(plan, runType: runType, personalityId: personalityId)
        return try await AIClient.shared.generateScript(plan: payload)
    }

    private func makeKey(plan: RunPlan, personalityId: String) -> String {
        // runType deliberately omitted — script content is largely
        // runtype-agnostic, so one cached script serves both buttons.
        "\(plan.kind.rawValue)|\(plan.distanceKm ?? 0)|\(plan.timeMinutes ?? 0)|\(personalityId)"
    }

    /// Warm the cache for any line likely to fire in the first ~90 seconds
    /// of the run. The warmup at t=0 must play instantly.
    private func prefetchEarlyLines(script: GeneratedScript) {
        var early: Set<String> = []
        for message in script.messages {
            switch message.triggerSpec.type {
            case .time:
                if let s = message.triggerSpec.atSeconds, s <= 90 {
                    for variant in message.rotationPool { early.insert(variant) }
                } else if message.triggerSpec.everySeconds != nil {
                    if let first = message.rotationPool.first { early.insert(first) }
                }
            case .distance:
                if message.triggerSpec.everyMeters != nil {
                    if let first = message.rotationPool.first { early.insert(first) }
                }
            default:
                break
            }
        }
        guard !early.isEmpty else { return }
        Task {
            for text in early {
                await RemoteTTS.shared.prefetch(text)
            }
        }
    }
}
