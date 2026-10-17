import AVFoundation
import Testing
import Foundation
import AARCKit
@testable import AARC

/// Pins the DJI remote protocol bytes against DJI's own published test frame
/// (Osmo-GPS-Controller-Demo, test/connect_cmd_frame_builder/connect_cmd_frame.txt)
/// and the status layout from protocol_data_segment.md. The night of 16 Oct
/// 2026 was lost to a length field two bytes short: the camera drops such a
/// frame without a word, so the builder is held to the byte.
@Suite("DJI camera protocol")
struct CameraProtocolHarness {

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    @Test("connection request reproduces DJI's reference frame byte for byte")
    func referenceFrame() {
        let ref = hex("AA330002000000000100982F00197856341206383456789ABC00000000000000000000000000000000FE1F00000000796C667C")
        let payload = DJIProtocol.connectionRequest(
            deviceId: 0x1234_5678, mac: [0x38, 0x34, 0x56, 0x78, 0x9A, 0xBC], verifyMode: 0, verifyData: 0x1FFE)
        let mine = DJIProtocol.frame(cmdSet: 0x00, cmdId: 0x19, cmdType: DJIProtocol.cmdWaitResult, payload: payload, seq: 1)
        #expect(mine == ref)
        #expect(mine.count == 51)
        #expect(Int(mine[1]) | (Int(mine[2]) << 8) == 51)
    }

    @Test("parse rejects a frame whose length field is short, accepts the reference")
    func parseLength() {
        let ref = hex("AA330002000000000100982F00197856341206383456789ABC00000000000000000000000000000000FE1F00000000796C667C")
        let f = DJIProtocol.parse(ref)
        #expect(f?.cmdSet == 0x00 && f?.cmdId == 0x19 && f?.seq == 1 && f?.isAck == false)
        var short = ref
        short[1] = 0x31   // the bug: 49 instead of 51
        #expect(DJIProtocol.parse(short) == nil)
    }

    @Test("the camera's handshake answer and request parse as they arrived from an Action 6")
    func handshakeFrames() {
        // Captured 16 Oct 2026 00:56 local: ack to our request, then the camera's own request.
        let ack = hex("55ff00000000000000")
        #expect(ack.count >= 5 && ack[4] == 0)
        let req = DJIProtocol.parseConnectionRequest(
            hex("55ff00000000000000000000000000000000000000000000000002000000000000"))
        #expect(req?.deviceId == 0xFF55)
        #expect(req?.verifyMode == 2)
        #expect(req?.verifyData == 0)
        #expect(DJIProtocol.modelName(deviceId: 0xFF55) == "Osmo Action 6")
    }

    @Test("status push: battery, recording and card from the documented offsets")
    func statusPush() {
        var d = [UInt8](repeating: 0, count: 38)
        d[0] = 0x01            // video
        d[1] = 0x03            // recording
        d[5] = 0x2C; d[6] = 0x01   // 300 s
        d[15] = 0x10; d[16] = 0x27 // 10000 MB
        d[23] = 0xB0; d[24] = 0x04 // 1200 s left
        d[28] = 0            // awake
        d[30] = 1            // warm
        d[37] = 84
        let s = DJIProtocol.parseStatus(d)
        #expect(s?.isRecording == true)
        #expect(s?.isVideoMode == true)
        #expect(s?.recordTimeSec == 300)
        #expect(s?.remainCapacityMB == 10000)
        #expect(s?.remainTimeSec == 1200)
        #expect(s?.batteryPercent == 84)
        #expect(s?.tempOver == 1)
        #expect(DJIProtocol.parseStatus(Array(d.prefix(37))) == nil)
    }

    @Test("reassembler drops the 0x55 frames and splits glued 0xAA frames")
    func reassembly() {
        let ack = DJIProtocol.frame(cmdSet: 0x1D, cmdId: 0x03, cmdType: DJIProtocol.ack, payload: [0], seq: 7)
        let junk = hex("552f046305253c13000d0200870e0000d5fcffff00000000000000009001001c000000000000200000000000012c9f")
        var r = DJIProtocol.Reassembler()
        #expect(r.feed(junk).isEmpty)
        let glued = ack + ack
        let first = r.feed(Array(glued.prefix(10)))
        #expect(first.isEmpty)
        let rest = r.feed(Array(glued.dropFirst(10)))
        #expect(rest.count == 2)
        #expect(rest.first?.key == "1D03" && rest.first?.isAck == true && rest.first?.data == [0])
    }

    @Test("record and mode payloads carry the device id and the right verb")
    func commandPayloads() {
        #expect(DJIProtocol.recordControl(deviceId: 0x5AA7_C001, start: true) == [0x01, 0xC0, 0xA7, 0x5A, 0, 0, 0, 0, 0])
        #expect(DJIProtocol.recordControl(deviceId: 0x5AA7_C001, start: false)[4] == 1)
        #expect(DJIProtocol.modeSwitch(deviceId: 1, mode: DJIProtocol.modeVideo) == [1, 0, 0, 0, 1, 0, 0, 0, 0])
        #expect(DJIProtocol.statusSubscription == [3, 20, 0, 0, 0, 0])
    }
}

/// Race day: the watch holds the race clock in the corral; the phone must keep
/// every engine quiet until the gate press, then run exactly as on any run.
@MainActor
@Suite("Race gate", .serialized)
struct RaceGateHarness {
    private func tick(_ dist: Double, awaiting: Bool?) -> LiveMetrics {
        LiveMetrics(elapsed: awaiting == true ? 0 : 600, distanceMeters: awaiting == true ? 0 : dist,
                    currentPaceSecPerKm: 340, avgPaceSecPerKm: 345, currentHeartRate: 150, energyKcal: 100,
                    lastSplit: nil, state: .running, awaitingGate: awaiting, gateCrossedAt: awaiting == true ? nil : .now)
    }

    @Test("corral ticks set awaitingGate; the first race tick clears it and keeps the run")
    func corralThenGate() {
        let c = LiveMetricsConsumer.shared
        c.latest = nil; c.currentRunId = nil
        UnfinishedRunStore.clear()
        RunSummaryStore.shared.dismiss()
        c.ingest(tick(0, awaiting: true))
        #expect(c.awaitingGate)
        #expect(c.isRunActive)
        c.ingest(tick(0, awaiting: true))
        #expect(c.awaitingGate)
        c.ingest(tick(1800, awaiting: nil))
        #expect(!c.awaitingGate)
        #expect(c.gateCrossedAt != nil)
        #expect(c.latest?.distanceMeters == 1800)
        c.endNow()
        c.latest = nil; c.currentRunId = nil
        UnfinishedRunStore.clear()
    }

    @Test("an ordinary run never enters the corral")
    func plainRun() {
        let c = LiveMetricsConsumer.shared
        c.latest = nil; c.currentRunId = nil
        UnfinishedRunStore.clear()
        RunSummaryStore.shared.dismiss()
        c.ingest(tick(400, awaiting: nil))
        #expect(!c.awaitingGate)
        #expect(c.gateCrossedAt == nil)
        c.endNow()
        c.latest = nil; c.currentRunId = nil
        UnfinishedRunStore.clear()
    }
}

/// The offline race pack is used only for the exact plan, run type and coach
/// it was built for; the one-shot course lines must sit mid-kilometre so they
/// never stack on the kilometre call Home Base owns.
@MainActor
@Suite("Race pack")
struct RacePackHarness {
    private func pack(planKm: Double, runType: String = "outdoor", persona: String = "roast_coach") -> RacePack {
        let plan = RunPlan(kind: .distance, distanceKm: planKm, timeMinutes: nil)
        let msg = ScriptMessage(id: "course_5", triggerSpec: TriggerSpec(type: .distance, atMeters: 4600),
                                text: "Astor Hotel. 1863. Older than your excuses.")
        return RacePack(planKey: RacePack.key(plan: plan, personalityId: persona), runType: runType,
                        personalityId: persona, courseId: "tianjin2026", builtAt: .now,
                        script: GeneratedScript(scriptId: "s", model: "m", messages: [msg]),
                        warmedLines: 1, totalLines: 1)
    }

    @Test("the pack matches only its own plan, run type and coach")
    func matching() {
        let store = RacePackStore.shared
        let race = RunPlan(kind: .distance, distanceKm: 42.195, timeMinutes: nil)
        let other = RunPlan(kind: .distance, distanceKm: 10, timeMinutes: nil)
        let p = pack(planKm: 42.195)
        #expect(p.planKey == RacePack.key(plan: race, personalityId: "roast_coach"))
        #expect(p.planKey != RacePack.key(plan: other, personalityId: "roast_coach"))
        #expect(p.planKey != RacePack.key(plan: race, personalityId: "jessica"))
        #expect(p.runType == RunType.outdoor.rawValue)
        #expect(p.lineCount == 1)
        #expect(store.usablePack(plan: race, runType: .outdoor, personalityId: "roast_coach")?.planKey == store.pack?.planKey)
    }

    @Test("the pack survives a round trip through its on-disk encoding")
    func codable() throws {
        let p = pack(planKm: 42.195)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(RacePack.self, from: enc.encode(p))
        #expect(back.planKey == p.planKey)
        #expect(back.script.messages.first?.triggerSpec.atMeters == 4600)
        #expect(RacePackLocalLines.all.count == 2)
    }
}

// MARK: - Talk-back channel (Siri → Control Room)

@Suite("Control Room channel", .serialized)
@MainActor
struct ControlRoomChannelHarness {
    private func fresh() -> (ControlRoomChannel, UserDefaults) {
        let name = "controlroom-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (ControlRoomChannel(defaults: d), d)
    }

    @Test("a line said in a dead spot is queued, kept in order, and capped")
    func queue() {
        let (ch, _) = fresh()
        #expect(ch.pending.isEmpty)
        for i in 0..<60 {
            ch.pending.append(.init(text: "line \(i)", runId: "r", km: Double(i), elapsed: 1, at: .now))
        }
        #expect(ch.pending.count == 50)
        #expect(ch.pending.first?.text == "line 10")
        #expect(ch.pending.last?.text == "line 59")
    }

    @Test("the queue survives a relaunch through its on-disk encoding")
    func persists() {
        let (ch, d) = fresh()
        ch.pending = [.init(text: "hey", runId: nil, km: nil, elapsed: nil, at: .now)]
        let again = ControlRoomChannel(defaults: d)
        #expect(again.pending.map(\.text) == ["hey"])
        again.pending = []
        #expect(d.data(forKey: "aarc.controlRoom.pending") == nil)
    }

    @Test("an empty line is a no-op, not a queued blank")
    func blank() async {
        let (ch, _) = fresh()
        #expect(await ch.say("   ") == .sent)
        #expect(ch.pending.isEmpty)
    }
}

@Suite("Talk-back segments")
struct TalkbackSegmentHarness {
    /// A tone of `seconds`, AAC in m4a, like the recorder writes.
    private func segment(_ name: String, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000])
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.3) }
        try file.write(from: buf)
        return url
    }

    @Test("segments are joined end to end, nothing overwritten")
    func joins() async throws {
        let a = try segment("a", seconds: 3), b = try segment("b", seconds: 0.4), c = try segment("c", seconds: 2)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("joined-\(UUID().uuidString).m4a")
        #expect(await ControlRoomRecorder.join([a, b, c], into: out))
        let dur = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(dur > 5.0 && dur < 5.8)
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test("a single segment is just moved into place")
    func single() async throws {
        let a = try segment("solo", seconds: 1.5)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("solo-\(UUID().uuidString).m4a")
        #expect(await ControlRoomRecorder.join([a], into: out))
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}
