import Testing
import Foundation
import AARCKit
@testable import AARC

/// Harness B: the 18 Oct field failures, pinned. A camera line cut Ricky's
/// opening, and a start on a dead network refused to begin the run.
@MainActor
@Suite("18 Oct field fixes", .serialized)
struct FieldFixesHarness {

    private func line(_ source: String, _ p: VoicePriority) -> VoiceItem {
        VoiceItem(text: "x", priority: p, source: source)
    }

    @Test func controlRoomLinesNeverCutALine() {
        let ricky = line("script:fast_start_opener", .coaching)
        for src in ["home", "home:camera:rec", "home:readout:km3", "home:watchdog", "home:gate"] {
            #expect(!VoiceFeedbackQueue.preempts(line(src, .milestone), over: ricky), "\(src) cut Ricky")
        }
    }

    @Test func kmSplitStillLandsOnTheMarker() {
        #expect(VoiceFeedbackQueue.preempts(line("script:km", .milestone), over: line("coach:dyn", .coaching)))
    }

    @Test func stashedOpenerIsUsedOnceForItsOwnPlan() {
        let key = "test|\(UUID().uuidString)"
        OpenerStash.put("Line A", key: key, runType: .outdoor)
        #expect(OpenerStash.take(key: key, runType: .treadmill) == nil)
        #expect(OpenerStash.take(key: key, runType: .outdoor) == "Line A")
        #expect(OpenerStash.take(key: key, runType: .outdoor) == nil)
    }

    @Test func fixedOpenerNamesThePlanWithoutDashes() {
        let line = OpenerStash.fixedLine(plan: RunPlan(kind: .distance, distanceKm: 20, timeMinutes: nil))
        #expect(line.contains("20 kilometres"))
        #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"))
    }

    @Test func slowOpenerGivesUpInsteadOfBlockingTheStart() async {
        let hung = Task<String, Error> { try await Task.sleep(for: .seconds(30)); return "late" }
        let t0 = Date.now
        let v = await RunOrchestrator.value(of: hung, within: 0.3)
        #expect(v == nil)
        #expect(Date.now.timeIntervalSince(t0) < 2)
        hung.cancel()
    }
}

/// Flying dark (race day: assume the first half hour has no network).
@MainActor
@Suite("Flying dark", .serialized)
struct FlyingDarkHarness {

    @Test func darkSynthGivesUpAtOnce() async {
        EndpointManager.shared.setDark(true, why: "test")
        defer { EndpointManager.shared.setDark(false, why: "test") }
        let t0 = Date.now
        let ok = await RemoteTTS.shared.prefetch("dark test line \(UUID())", within: 30)
        #expect(!ok)
        #expect(Date.now.timeIntervalSince(t0) < 1)
    }

    @Test func darkKilometreGoesToRickyAtOnce() {
        EndpointManager.shared.setDark(true, why: "test")
        defer { EndpointManager.shared.setDark(false, why: "test") }
        HomeBaseReadout.shared.reset()
        var fell = false
        let m = LiveMetrics(elapsed: 330, distanceMeters: 1000, currentPaceSecPerKm: 330, avgPaceSecPerKm: 330,
                            currentHeartRate: 150, energyKcal: 60, cadenceStepsPerMinute: 170, lastSplit: nil, state: .running)
        HomeBaseReadout.shared.deliver(km: 1, metrics: m) { fell = true }
        #expect(fell)
    }

    @Test func everyCameraBatteryLineIsPreRendered() {
        #expect(RaceCameraDirector.spoken(87) == 85)
        #expect(RaceCameraDirector.spoken(3) == 5)
        let lines = Set(RaceCameraDirector.packLines)
        for b in 0...100 {
            #expect(lines.contains("Camera recording, battery \(RaceCameraDirector.spoken(b)) percent."))
        }
    }

    @Test func darkLineNeverHoldsTheQueue() async {
        EndpointManager.shared.setDark(true, why: "test")
        defer { EndpointManager.shared.setDark(false, why: "test") }
        let q = VoiceFeedbackQueue.shared
        q.stopAll()
        Speaker.shared.speak("Dark.", priority: .milestone, source: "script:km")
        let t0 = Date.now
        while Date.now.timeIntervalSince(t0) < 15, q.currentlyPlaying != nil || !q.pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(q.currentlyPlaying == nil && q.pending.isEmpty, "an uncached line held the slot while dark")
        q.stopAll()
    }
}

/// Actual race: one race, and the arch is the finish (18 Oct).
@MainActor
@Suite("Race day plan", .serialized)
struct RaceDayPlanHarness {
    @Test func actualRaceLocksTheMarathonAndNeverCallsTheFinishOnDistance() {
        let o = RunOrchestrator.shared
        let before = o.raceMode
        defer { o.raceMode = before }
        o.raceMode = .actual
        let plan = ScriptPreviewStore.shared.currentPlan
        #expect(plan.kind == .distance && plan.distanceKm == RunOrchestrator.marathonKm)
        let finish = ScriptMessage(id: "f", triggerSpec: TriggerSpec(type: .finish), text: "x", textVariants: nil, priority: 1, playOnce: true)
        #expect(MilestoneAnnouncement.text(for: finish, plan: plan, distanceMeters: 42_300, elapsedSeconds: 14_000) == MilestoneAnnouncement.raceFinishText)
        let km = ScriptMessage(id: "k", triggerSpec: TriggerSpec(type: .distance, everyMeters: 1000), text: "x", textVariants: nil, priority: 1, playOnce: false)
        let late = MilestoneAnnouncement.text(for: km, plan: plan, distanceMeters: 43_050, elapsedSeconds: 14_300) ?? ""
        #expect(!late.contains("past your goal"))
        let pack = Set(MilestoneAnnouncement.prefetchTexts(for: plan))
        #expect(pack.contains(MilestoneAnnouncement.raceFinishText) && pack.contains(late))
    }
}
