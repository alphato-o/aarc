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
