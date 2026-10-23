import Foundation

/// Race-day rehearsal at the desk (23 Oct, before the Tianjin marathon): the
/// real app runs an actual race on the simulator through the whole pipeline
/// (race pack or script, Home Base readouts, live uplink, course book by GPS,
/// finish, closing readout, post-run window) while the agent watches the live
/// feed. `AARC_RACE_SIM=<speed>`, optional `AARC_RACE_SIM_FROM_KM=<km>` to
/// start late. The run is a test run: nothing reaches Health.
@MainActor
enum RaceSimHarness {
    static var speed: Double? {
        ProcessInfo.processInfo.environment["AARC_RACE_SIM"].flatMap(Double.init)
    }

    static func run(speed: Double) async {
        let env = ProcessInfo.processInfo.environment
        let orchestrator = RunOrchestrator.shared
        orchestrator.raceMode = .actual
        orchestrator.testMode = .simulate
        RunSimulator.shared.speedMultiplier = speed
        NSLog("AARC_RACE_SIM ▶ actual race, simulate, \(speed)x")
        await orchestrator.startPhoneOnly(runType: .outdoor)
        let sim = RunSimulator.shared
        guard sim.isActive else {
            NSLog("AARC_RACE_SIM ✗ the run did not start: \(orchestrator.lastError ?? "no error")")
            return
        }
        if let from = env["AARC_RACE_SIM_FROM_KM"].flatMap(Double.init), from > 0 {
            try? await Task.sleep(for: .seconds(20))
            sim.jump(meters: from * 1000)
        }
        // The watch reads about 1% long: the arch comes at 42.6 on the watch.
        let finish = 42_195 * 1.01 + 30
        while sim.isActive, (LiveMetricsConsumer.shared.latest?.distanceMeters ?? 0) < finish {
            try? await Task.sleep(for: .seconds(5))
        }
        NSLog("AARC_RACE_SIM ■ at the arch, ending")
        sim.end()
    }
}
