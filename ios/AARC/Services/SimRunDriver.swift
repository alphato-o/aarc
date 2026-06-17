import Foundation
import AARCKit

/// Harness A — the whole-run feedback simulator (Content mode, v1).
///
/// Fast-forwards a virtual run through the REAL generation pipeline
/// (RunDirector / ScriptEngine / Conversation / AIClient), text-only — no
/// ElevenLabs. Reuses `RunOrchestrator.startPhoneOnly` in `.simulate` mode for
/// the genuine setup (opener + full-script generation, `ingestStarted`), then
/// takes over the 1 Hz tick with a stepped virtual clock and records every
/// produced line via `RunPreview`.
///
/// KNOWN v1 GAP: `ContextualCoach`'s reactive triggers (quiet_stretch, pace
/// drop/surge, hr spike) are wall-clock (`Date()`) driven, so they under-fire
/// in a fast sim — Ricky's *reactive* lines are under-represented here.
/// Jessica (Conversation), the scripted milestones (ScriptEngine), and the
/// director's ownership curve are all `metrics.elapsed`-driven and reproduce
/// faithfully. Closing the reactive gap needs the `Clock` seam (spec §5, P4).
@MainActor
enum SimRunDriver {

    static func runAndWrite(planArg: String) async {
        let km = parsePlanKm(planArg)
        let pace = 340.0   // 5:40/km — representative
        NSLog("AARC_RUN_SIM ▶ starting headless content-mode preview: \(km)k @ \(pace)s/km")
        let json = await run(planKm: km, paceSecPerKm: pace)
        guard let json else { NSLog("AARC_RUN_SIM ✗ no transcript produced"); return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("run-sim-\(Int(km))k.json")
        try? json.write(to: url)
        NSLog("AARC_RUN_SIM ✓ wrote \(RunPreview.shared.lines.count) lines to \(url.path)")
    }

    /// Run a headless content-mode preview and return the transcript JSON.
    static func run(planKm: Double, paceSecPerKm: Double = 340, runType: RunType = .treadmill) async -> Data? {
        // Save persisted settings the harness mutates, so a preview launch can
        // never leave the app stuck in simulate mode / on the wrong plan.
        let prevMode = RunOrchestrator.shared.testMode
        let prevKind = ScriptPreviewStore.shared.planKind
        let prevDist = ScriptPreviewStore.shared.distanceKm
        defer {
            RunOrchestrator.shared.testMode = prevMode
            ScriptPreviewStore.shared.planKind = prevKind
            ScriptPreviewStore.shared.distanceKm = prevDist
        }

        // --- setup: simulate mode, plan, recorder on, no prewarm network ---
        RunOrchestrator.shared.testMode = .simulate
        ScriptPreviewStore.shared.planKind = .distance
        ScriptPreviewStore.shared.distanceKm = planKm
        RunSimulator.shared.headless = true       // skip the real 1 Hz Timer
        RunSimulator.shared.autoVary = false      // kill Double.random pace wander → deterministic
        RunSimulator.shared.paceSecPerKm = paceSecPerKm
        RunDirector.shared.prewarmEnabled = false // no TTS prefetch network calls
        RunPreview.shared.begin()

        // Install the VIRTUAL clock so ContextualCoach / ScriptEngine /
        // RunDirector run their time-based pacing (cooldowns, sustain, quiet-
        // stretch) against fast-forwarded time — otherwise reactive (Ricky)
        // lines under-fire in a fast sim. Reset on exit.
        let clockBase = Date()
        AppClock.override = { clockBase.addingTimeInterval(RunPreview.shared.virtualElapsed) }
        defer { AppClock.override = nil }

        // Real setup: opener gen + full-script gen scheduled + ingestStarted
        // (engines started) via RunSimulator.start (headless ⇒ no Timer).
        await RunOrchestrator.shared.startPhoneOnly(runType: runType)

        // Bounded wait for the full Sonnet script to land so the per-km
        // milestone pool exists. If it 502s out (as on run 24285006), we
        // proceed opener-only — faithfully reproducing the no-milestones case.
        let scriptDeadline = Date().addingTimeInterval(90)
        while (ScriptPreviewStore.shared.latest?.messages.count ?? 0) <= 1,
              Date() < scriptDeadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let gotFullScript = (ScriptPreviewStore.shared.latest?.messages.count ?? 0) > 1
        NSLog("AARC_RUN_SIM full script: \(gotFullScript ? "landed (\(ScriptPreviewStore.shared.latest?.messages.count ?? 0) msgs)" : "FAILED — opener only")")

        // --- step the virtual clock through the run ---
        let dt = 3.0
        let totalMeters = planKm * 1000
        let speed = 1000.0 / max(60, paceSecPerKm)   // m/s
        var t = 0.0, dist = 0.0
        while dist < totalMeters && t < 4 * 3600 {
            t += dt
            dist += speed * dt
            let hr = min(178, 120 + (t / 60) * 0.5)   // gentle cardiac drift
            RunPreview.shared.virtualElapsed = t
            let m = LiveMetrics(
                elapsed: t,
                distanceMeters: dist,
                currentPaceSecPerKm: paceSecPerKm,
                avgPaceSecPerKm: dist > 0 ? t / (dist / 1000) : 0,
                currentHeartRate: hr,
                energyKcal: dist * 0.06,
                cadenceStepsPerMinute: 160,
                lastSplit: nil,
                state: .running
            )
            LiveMetricsConsumer.shared.ingest(m)
            await settle()   // let line N finish + be remembered before line N+1
        }

        // --- teardown WITHOUT the full ingestEnded (no SwiftData / D1 writes) ---
        ScriptEngine.shared.stop()
        ContextualCoach.shared.stop()
        Conversation.shared.stop()
        RunDirector.shared.stop()
        RunPreview.shared.end()
        RunSimulator.shared.headless = false
        RunDirector.shared.prewarmEnabled = true

        return RunPreview.shared.transcriptJSON(plan: "\(Int(planKm))k", pace: paceSecPerKm)
    }

    /// Await in-flight generation so line N is recorded + folded into the
    /// anti-repeat context before line N+1 is generated (the dependency chain).
    private static func settle() async {
        let deadline = Date().addingTimeInterval(30)
        while (Conversation.shared.isProducing || ContextualCoach.shared.isGenerating),
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private static func parsePlanKm(_ arg: String) -> Double {
        let digits = arg.lowercased().replacingOccurrences(of: "k", with: "")
        return Double(digits.trimmingCharacters(in: .whitespaces)) ?? 10
    }
}
