import Foundation
import Observation
import AARCKit

/// Coordinates the "user wants to start a run" flow on the phone,
/// regardless of whether the trigger came from the iPhone (its own
/// Start button) or the Apple Watch (sent prepareWorkout to us).
///
/// Both paths converge on:
/// 1. Generate a Roast Coach script via AIClient (talks to proxy).
/// 2. Cache the script in ScriptPreviewStore (which ScriptEngine reads
///    at the moment the watch's HKWorkoutSession actually fires
///    workoutStarted).
/// 3. Pre-fetch the first few lines' TTS audio in the background so
///    the warmup line plays instantly at t=0 — no perceptible delay.
/// 4. Tell the watch what to do next:
///      - phone-initiated: send startWorkout (watch goes to countdown).
///      - watch-initiated: send scriptReady (watch transitions itself
///        from preparing → countdown).
@Observable
@MainActor
final class RunOrchestrator {
    static let shared = RunOrchestrator()

    enum Phase: String, Sendable {
        case idle
        case generating         // calling AIClient
        case sentToWatch        // phone-initiated: handed off to watch
        case error
    }

    private(set) var phase: Phase = .idle
    var lastError: String?

    /// Phone tapped Start. Generate first, then ask the watch to start.
    func startFromPhone(runType: RunType, personalityId: String = "roast_coach") async {
        guard phase != .generating else { return }
        phase = .generating
        lastError = nil

        let runId = UUID()
        do {
            let script = try await generate(
                plan: ScriptPreviewStore.shared.currentPlan,
                runType: runType,
                personalityId: personalityId
            )
            ScriptPreviewStore.shared.latest = script
            prefetchEarlyLines(script: script)

            PhoneSession.shared.sendStateEvent(
                .startWorkout(runId: runId, runType: runType, personalityId: personalityId)
            )
            phase = .sentToWatch
        } catch {
            phase = .error
            lastError = error.localizedDescription
        }
    }

    /// Watch sent prepareWorkout. Generate, then reply.
    func handlePrepareFromWatch(
        runId: UUID,
        runType: RunType,
        personalityId: String
    ) async {
        phase = .generating
        lastError = nil
        do {
            let script = try await generate(
                plan: ScriptPreviewStore.shared.currentPlan,
                runType: runType,
                personalityId: personalityId
            )
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

    /// Reset after dismissing an error so the user can retry.
    func clearError() {
        if phase == .error {
            phase = .idle
            lastError = nil
        }
    }

    // MARK: - Private

    private func generate(
        plan: RunPlan,
        runType: RunType,
        personalityId: String
    ) async throws -> GeneratedScript {
        let payload = AIClient.ScriptPlan.from(plan, runType: runType, personalityId: personalityId)
        return try await AIClient.shared.generateScript(plan: payload)
    }

    /// Background-prefetch TTS audio for any line that fires within the
    /// first ~90 seconds. The warmup at t=0 must play instantly — it's
    /// the first impression. Subsequent lines are warmed too where it's
    /// cheap. Best-effort; failures are silent (live speak() will retry
    /// or fall back to LocalTTS).
    private func prefetchEarlyLines(script: GeneratedScript) {
        let earlyTexts: [String] = script.messages.compactMap { message in
            guard message.triggerSpec.type == .time else { return nil }
            guard let s = message.triggerSpec.atSeconds, s <= 90 else { return nil }
            return message.text
        }
        guard !earlyTexts.isEmpty else { return }
        Task {
            for text in earlyTexts {
                await RemoteTTS.shared.prefetch(text)
            }
        }
    }
}
