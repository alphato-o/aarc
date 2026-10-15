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
