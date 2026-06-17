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
        await run(planKm: km, paceSecPerKm: pace)
    }

    /// Transcript output path for a plan.
    private static func outURL(km: Double) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("run-sim-\(Int(km))k.json")
    }

    /// Run a headless content-mode preview. Writes the transcript INCREMENTALLY
    /// (every new line) + a guaranteed final write on ANY exit — so a slow,
    /// stuck, or aborted run still yields a readable report. Robustness is the
    /// point: this harness must always finish with something on disk.
    static func run(planKm: Double, paceSecPerKm: Double = 340, runType: RunType = .treadmill) async {
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
        RemoteTTS.previewLeakCount = 0             // leak detector baseline

        // Install the VIRTUAL clock so ContextualCoach / ScriptEngine /
        // RunDirector run their time-based pacing (cooldowns, sustain, quiet-
        // stretch) against fast-forwarded time — otherwise reactive (Ricky)
        // lines under-fire in a fast sim. Reset on exit.
        let clockBase = Date()
        AppClock.override = { clockBase.addingTimeInterval(RunPreview.shared.virtualElapsed) }
        defer { AppClock.override = nil }

        // Write the transcript to disk; called incrementally + guaranteed once
        // on ANY exit so a slow/stuck/aborted run still leaves a readable report.
        let url = outURL(km: planKm)
        func flush() {
            if let d = RunPreview.shared.transcriptJSON(plan: "\(Int(planKm))k", pace: paceSecPerKm) {
                try? d.write(to: url)
            }
        }
        defer {
            flush()
            let leaks = RemoteTTS.previewLeakCount
            NSLog("AARC_RUN_SIM ✓ \(RunPreview.shared.lines.count) lines → \(url.lastPathComponent) · EL leak \(leaks)\(leaks > 0 ? " ⚠️ LEAK" : " ✓")")
        }

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
        // Overall wall-clock budget: a single hung/stalled LLM call must NOT
        // hang the whole preview. When the budget is hit we stop and write
        // whatever transcript we have (a partial preview is still useful).
        let runDeadline = Date().addingTimeInterval(12 * 60)   // hard wall-clock cap
        let dt = 3.0
        let totalMeters = planKm * 1000
        let speed = 1000.0 / max(60, paceSecPerKm)   // m/s
        var t = 0.0, dist = 0.0, lastCount = 0
        while dist < totalMeters && t < 4 * 3600 {
            if Date() >= runDeadline {
                NSLog("AARC_RUN_SIM ⏱ 12-min budget hit at \(Int(dist))m / \(RunPreview.shared.lines.count) lines — finishing with a partial transcript")
                break
            }
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
            // Incremental write + progress whenever a new line lands, so the
            // report on disk is always current even if we're later killed.
            if RunPreview.shared.lines.count != lastCount {
                lastCount = RunPreview.shared.lines.count
                flush()
                NSLog("AARC_RUN_SIM … \(lastCount) lines · \(Int(dist/1000))k · \(Int(t/60))m virtual")
            }
        }

        // --- teardown WITHOUT the full ingestEnded (no SwiftData / D1 writes) ---
        ScriptEngine.shared.stop()
        ContextualCoach.shared.stop()
        Conversation.shared.stop()
        RunDirector.shared.stop()
        RunPreview.shared.end()
        RunSimulator.shared.headless = false
        RunDirector.shared.prewarmEnabled = true
        // (final transcript write + leak verdict happen in the guaranteed defer)
    }

    /// Await in-flight generation so line N is recorded + folded into the
    /// anti-repeat context before line N+1 is generated (the dependency chain).
    /// Caps at 20s so a single hung generation can't stall every later tick for
    /// the full 30s — the run keeps moving and the budget still bounds the rest.
    private static func settle() async {
        let deadline = Date().addingTimeInterval(20)
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
