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

    /// Speculative opener generation (fast, single Haiku call ~2-5s).
    /// Lets the user start running before the full Sonnet script is
    /// ready. The actual `start*` methods await this if it's still
    /// running, or use the result instantly if it's complete.
    ///
    /// Keyed by run type because the opener references the runner's
    /// setting (outdoor scenery vs the treadmill belt) and the run type
    /// isn't known until the user taps one of the two Start buttons. We
    /// speculatively generate BOTH so whichever they pick is instant and
    /// correctly themed. The full Sonnet script is NOT pre-generated —
    /// it's generated at Start with the true run type (it swaps in well
    /// before km 1 at any pace, so there's no perceived latency, and we
    /// don't burn Sonnet tokens on a speculative script that's usually
    /// the wrong run type or never used at all).
    private var preGenOpenerTasks: [RunType: Task<String, Error>] = [:]

    /// Active full-script-swap task — pulls the full script (either
    /// from the in-flight pre-gen or a fresh /generate-script call) and
    /// hands it to ScriptEngine.replaceScript when ready. Cancelled at
    /// stop / restart so a stale swap can't trample a fresh run.
    private var fullScriptSwapTask: Task<Void, Never>?

    private var preGenKey: String?

    /// Phone tapped Start in PHONE-ONLY mode. Phone tracks the run via
    /// CoreLocation + HKWorkoutBuilder (no watch involvement). Same
    /// downstream pipeline (ScriptEngine, ContextualCoach, Live Activity)
    /// because PhoneWorkoutSession publishes the same LiveMetrics shape.
    func startPhoneOnly(runType: RunType, personalityId: String = "roast_coach") async {
        guard phase != .generating else { return }
        phase = .generating
        lastError = nil

        // Reshuffle the personal-context bullet rotation: each run picks
        // a fresh 20-of-N subset, but the seed is stable across opener,
        // script, dynamic-line, and music-comment calls within this run
        // so the proxy prompt cache stays warm.
        PersonalContextStore.shared.rerollRotation()

        let plan = ScriptPreviewStore.shared.currentPlan
        let runId = UUID()

        do {
            let stub = try await prepareOpenerStub(plan: plan, runType: runType, personalityId: personalityId)
            ScriptPreviewStore.shared.latest = stub
            prefetchEarlyLines(script: stub)

            try await PhoneWorkoutSession.shared.start(
                runType: runType,
                runId: runId,
                personalityId: personalityId
            )
            scheduleFullScriptSwap(plan: plan, runType: runType, personalityId: personalityId)
            // No watch involvement — no startWorkout WC message, no
            // wrist-cue notification. The phone is tracking, done.
            phase = .idle
        } catch {
            phase = .error
            lastError = error.localizedDescription
        }
    }

    /// Phone tapped Start. Use the pre-gen opener if ready, else generate.
    /// Full script is kicked off in the background and swapped into
    /// ScriptEngine when ready.
    func startFromPhone(runType: RunType, personalityId: String = "roast_coach") async {
        guard phase != .generating else { return }
        phase = .generating
        lastError = nil

        // Stash so the Live Activity (started later from ingestStarted)
        // can render the right label.
        LiveMetricsConsumer.shared.pendingRunType = runType
        LiveMetricsConsumer.shared.pendingPersonalityId = personalityId

        let plan = ScriptPreviewStore.shared.currentPlan
        let runId = UUID()

        do {
            let stub = try await prepareOpenerStub(plan: plan, runType: runType, personalityId: personalityId)
            ScriptPreviewStore.shared.latest = stub
            prefetchEarlyLines(script: stub)

            PhoneSession.shared.sendStateEvent(
                .startWorkout(runId: runId, runType: runType, personalityId: personalityId)
            )
            scheduleFullScriptSwap(plan: plan, runType: runType, personalityId: personalityId)
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

    /// Watch sent prepareWorkout. Same opener-first flow, then reply
    /// over WC so the watch transitions to its countdown screen.
    func handlePrepareFromWatch(
        runId: UUID,
        runType: RunType,
        personalityId: String
    ) async {
        phase = .generating
        lastError = nil

        let plan = ScriptPreviewStore.shared.currentPlan

        do {
            let stub = try await prepareOpenerStub(plan: plan, runType: runType, personalityId: personalityId)
            ScriptPreviewStore.shared.latest = stub
            prefetchEarlyLines(script: stub)
            PhoneSession.shared.sendStateEvent(.scriptReady(scriptId: stub.scriptId))
            scheduleFullScriptSwap(plan: plan, runType: runType, personalityId: personalityId)
            phase = .idle
        } catch {
            phase = .error
            lastError = error.localizedDescription
            PhoneSession.shared.sendStateEvent(
                .scriptFailed(reason: error.localizedDescription)
            )
        }
    }

    /// Kick off speculative generation in the background: the fast
    /// opener (so Start is near-instant) and the full Sonnet script
    /// (so it's ready to swap in shortly after the run begins).
    /// Idempotent for the same plan/personality — re-runs cancel and
    /// replace the in-flight tasks if the key changes.
    /// Called by RunHomeView on appear and on plan/personality change.
    func schedulePreGenerate(personalityId: String = "roast_coach") {
        let plan = ScriptPreviewStore.shared.currentPlan
        let key = makeKey(plan: plan, personalityId: personalityId)

        if preGenKey == key, !preGenOpenerTasks.isEmpty { return }
        preGenOpenerTasks.values.forEach { $0.cancel() }
        preGenOpenerTasks.removeAll()
        preGenKey = key
        isPreGenerating = true

        // Fresh bullet rotation for this pre-gen cycle; same seed will
        // then be reused by the runtime calls (dynamic-line, etc.) so
        // they all hit the prompt cache together.
        PersonalContextStore.shared.rerollRotation()

        // Speculatively generate the opener for BOTH run types — the
        // user hasn't picked yet (they pick by tapping the Outdoor or
        // Treadmill Start button), and the opener references the setting.
        // Whichever button they tap then resolves instantly to the
        // correctly-themed opener.
        for runType in [RunType.outdoor, RunType.treadmill] {
            preGenOpenerTasks[runType] = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.generateOpener(
                    plan: plan,
                    runType: runType,
                    personalityId: personalityId
                )
            }
        }

        // Clear the "pre-loading" hint once both openers settle. The
        // full script is generated lazily at Start, so there's nothing
        // else to wait on here.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tasks = Array(self.preGenOpenerTasks.values)
            for task in tasks { _ = try? await task.value }
            self.isPreGenerating = false
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

    /// Build a stub script containing only the opener line, ready to
    /// hand to ScriptPreviewStore so ScriptEngine.start fires it as the
    /// t=0 trigger of the run. Awaits the pre-gen opener task if one
    /// is in flight, otherwise generates a fresh one. Resulting text is
    /// also prefetched to AudioCache so playback at t=0 is instant.
    private func prepareOpenerStub(
        plan: RunPlan,
        runType: RunType,
        personalityId: String
    ) async throws -> GeneratedScript {
        let openerText = try await resolveOpener(
            plan: plan,
            runType: runType,
            personalityId: personalityId
        )
        // Best-effort warm of the audio cache so the opener plays
        // instantly when the workout starts.
        Task { await RemoteTTS.shared.prefetch(openerText) }
        return makeStubScript(openerText: openerText)
    }

    private func resolveOpener(
        plan: RunPlan,
        runType: RunType,
        personalityId: String
    ) async throws -> String {
        let key = makeKey(plan: plan, personalityId: personalityId)
        if preGenKey == key, let task = preGenOpenerTasks[runType] {
            do {
                let text = try await task.value
                preGenOpenerTasks[runType] = nil
                return text
            } catch {
                preGenOpenerTasks[runType] = nil
            }
        }
        return try await generateOpener(
            plan: plan,
            runType: runType,
            personalityId: personalityId
        )
    }

    private func generateOpener(
        plan: RunPlan,
        runType: RunType,
        personalityId: String
    ) async throws -> String {
        let bullets = PersonalContextStore.shared.bullets
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: personalityId)
        let result = try await AIClient.shared.generateOpener(
            plan: plan,
            runType: runType,
            personalityId: personalityId,
            personalNotes: bullets.isEmpty ? nil : bullets,
            likedLineExamples: liked.isEmpty ? nil : liked
        )
        return result.text
    }

    private func makeStubScript(openerText: String) -> GeneratedScript {
        let openerMessage = ScriptMessage(
            id: "fast_start_opener",
            triggerSpec: TriggerSpec(type: .time, atSeconds: 0),
            text: openerText,
            textVariants: nil,
            priority: 100,
            playOnce: true
        )
        return GeneratedScript(
            scriptId: "fast-start-\(UUID().uuidString)",
            model: "opener-stub",
            messages: [openerMessage]
        )
    }

    /// Kick off the full /generate-script Sonnet call in the
    /// background, then hand the result to ScriptEngine.replaceScript.
    /// Uses the pre-gen full task if it's in flight; otherwise spawns
    /// a fresh request.
    private func scheduleFullScriptSwap(
        plan: RunPlan,
        runType: RunType,
        personalityId: String
    ) {
        fullScriptSwapTask?.cancel()

        fullScriptSwapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Generate the full Sonnet script now, with the TRUE run
                // type the user just chose. Completes in ~30-50s and
                // swaps in before km 1 at any real pace; the opener
                // covers t=0 in the meantime.
                let full = try await self.generateFull(
                    plan: plan,
                    runType: runType,
                    personalityId: personalityId,
                    skipOpener: true
                )
                guard !Task.isCancelled else { return }
                // The full script was generated with skipOpener=true so
                // it doesn't include a t=0 line. Re-introduce the
                // opener that's already in the current stub so the
                // merged script can stand alone — important if the
                // swap happens BEFORE ScriptEngine.start runs (e.g.,
                // the watch is slow to send workoutStarted): when
                // ScriptEngine.start eventually reads the script from
                // ScriptPreviewStore, the opener still needs to be in
                // there to fire as the t=0 trigger.
                let opener = ScriptPreviewStore.shared.latest?.messages.first {
                    $0.id == "fast_start_opener"
                }
                let merged: GeneratedScript
                if let opener {
                    merged = GeneratedScript(
                        scriptId: full.scriptId,
                        model: full.model,
                        messages: [opener] + full.messages
                    )
                } else {
                    merged = full
                }
                // Swap into the engine using whatever metrics are
                // current. Anything already-passed gets pre-marked so
                // we don't replay every km the runner already crossed
                // (the fast_start_opener will be pre-marked too if its
                // t=0 trigger already fired).
                let metrics = LiveMetricsConsumer.shared.latest ?? .zero
                ScriptEngine.shared.replaceScript(merged, currentMetrics: metrics)
                ScriptPreviewStore.shared.latest = merged
                self.prefetchEarlyLines(script: merged)
            } catch {
                if Task.isCancelled { return }
                self.lastError = "full-script gen failed: \(error.localizedDescription)"
            }
        }
    }

    private func generateFull(
        plan: RunPlan,
        runType: RunType,
        personalityId: String,
        skipOpener: Bool
    ) async throws -> GeneratedScript {
        var payload = AIClient.ScriptPlan.from(plan, runType: runType, personalityId: personalityId)
        payload.skipOpener = skipOpener
        // Pipe the founder's personal-context bullets through as
        // userMemory — the coach uses them as trolling hooks (FydeOS
        // 10 users, Phi Browser dying, will-never-be-Sam-Altman, etc.).
        let bullets = PersonalContextStore.shared.bullets
        if !bullets.isEmpty {
            payload.userMemory = bullets
        }
        // Liked lines from past runs as vibe-only calibration.
        let liked = LikedLinesStore.shared.vibeExemplars(personalityId: personalityId)
        if !liked.isEmpty {
            payload.likedLineExamples = liked
        }
        return try await AIClient.shared.generateScript(plan: payload)
    }

    private func makeKey(plan: RunPlan, personalityId: String) -> String {
        // runType deliberately omitted — this key identifies the
        // plan/personality the pre-gen openers were built for; the two
        // run types are held separately in `preGenOpenerTasks` and
        // looked up by run type in `resolveOpener`.
        "\(plan.kind.rawValue)|\(plan.distanceKm ?? 0)|\(plan.timeMinutes ?? 0)|\(personalityId)"
    }

    /// Warm the cache for any line likely to fire in the first ~90 seconds
    /// of the run. The warmup at t=0 must play instantly.
    ///
    /// Two layers:
    ///   1. **Script lines** — first variant of each looping trigger plus
    ///      any time.atSeconds line within the warmup window. Personality
    ///      content; cache hit only on identical text, so per-run novelty
    ///      means we usually pay the network round-trip once.
    ///   2. **Milestone announcements** — deterministic, factual prefixes
    ///      ("3 kilometres.", "Halfway through.", "Run complete."). Same
    ///      text every run → cached on disk after the first run, instant
    ///      playback forever after. Covered by `MilestoneAnnouncement`.
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
                    // Warm the WHOLE rotation pool, not just the first
                    // variant — the per-km loop reuses these same lines
                    // every km for the rest of the run, so warming all of
                    // them once means every split's roast plays instantly
                    // (the director's pre-warm covers the deterministic
                    // announcement; this covers the personality line).
                    for variant in message.rotationPool { early.insert(variant) }
                }
            default:
                break
            }
        }
        let plan = ScriptPreviewStore.shared.currentPlan
        let announcements = MilestoneAnnouncement.prefetchTexts(for: plan)
        early.formUnion(announcements)

        guard !early.isEmpty else { return }
        Task {
            for text in early {
                await RemoteTTS.shared.prefetch(text)
            }
        }
    }
}
