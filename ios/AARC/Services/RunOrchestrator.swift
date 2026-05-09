import Foundation
import Observation
import AARCKit

/// Coordinates the "user wants to start a run" flow on the phone,
/// regardless of whether the trigger came from the iPhone (its own
/// Start button) or the Apple Watch (sent prepareWorkout to us).
///
/// Both paths converge on:
/// 1. Generate a Roast Coach script via AIClient (talks to proxy).
/// 2. Cache it in ScriptPreviewStore (which ScriptEngine reads at the
///    moment the watch's HKWorkoutSession actually fires workoutStarted).
/// 3. Tell the watch what to do next:
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
                runType: runType,
                personalityId: personalityId
            )
            ScriptPreviewStore.shared.latest = script

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
                runType: runType,
                personalityId: personalityId
            )
            ScriptPreviewStore.shared.latest = script
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

    private func generate(runType: RunType, personalityId: String) async throws -> GeneratedScript {
        let plan = AIClient.ScriptPlan(
            goal: "free",
            distanceKm: ScriptPreviewStore.shared.distanceKm,
            targetPaceSecPerKm: ScriptPreviewStore.shared.paceMinPerKm * 60,
            personalityId: personalityId,
            runType: runType.rawValue
        )
        return try await AIClient.shared.generateScript(plan: plan)
    }
}
