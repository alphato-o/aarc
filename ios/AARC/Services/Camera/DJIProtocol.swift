import Foundation

/// DJI "R SDK" framing as spoken by Osmo Action 4 / 5 Pro / 6 and Osmo 360 over
/// BLE (service FFF0, write FFF5, notify FFF4). Reference: DJI's own
/// Osmo-GPS-Controller-Demo (github.com/dji-sdk). Pure functions, no I/O, so
/// the bytes can be pinned against DJI's published test frame.
///
/// Frame: AA | len16 LE (version<<10 | total length) | cmdType | enc | res×3 |
/// seq16 LE | CRC16 over the 10 bytes so far | cmdSet | cmdId | payload |
/// CRC32 over everything before it. Length counts the WHOLE frame (18 +
/// payload). A wrong length is dropped silently by the camera, which cost a
/// night of silence on 16 Oct 2026.
enum DJIProtocol {
    static let sof: UInt8 = 0xAA
    /// `cmdType` bit 5 marks a response frame.
    static let ack: UInt8 = 0x20
    static let cmdNoResponse: UInt8 = 0x00
    static let cmdResponseOrNot: UInt8 = 0x01
    static let cmdWaitResult: UInt8 = 0x02

    struct Frame: Equatable {
        let cmdType: UInt8
        let seq: UInt16
        let cmdSet: UInt8
        let cmdId: UInt8
        let data: [UInt8]
        var isAck: Bool { cmdType & DJIProtocol.ack != 0 }
        var key: String { String(format: "%02X%02X", cmdSet, cmdId) }
    }

    // MARK: CRCs (init 0x3AA3, reflected, no final xor: DJI's custom tables)

    private static let table16: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        return c
    }
    private static let table32: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0x3AA3
        for b in bytes { c = table16[Int((c ^ UInt16(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0x3AA3
        for b in bytes { c = table32[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    // MARK: Build / parse

    static func frame(cmdSet: UInt8, cmdId: UInt8, cmdType: UInt8, payload: [UInt8], seq: UInt16) -> [UInt8] {
        let total = UInt16(18 + payload.count) & 0x3FF
        var f: [UInt8] = [sof, UInt8(total & 0xFF), UInt8(total >> 8), cmdType, 0, 0, 0, 0,
                          UInt8(seq & 0xFF), UInt8(seq >> 8)]
        let c16 = crc16(f[0..<10])
        f += [UInt8(c16 & 0xFF), UInt8(c16 >> 8), cmdSet, cmdId]
        f += payload
        let c32 = crc32(f[0..<f.count])
        f += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8(c32 >> 24)]
        return f
    }

    /// Parse one complete frame. nil for anything that is not a valid 0xAA frame
    /// (the Action 5 Pro / 6 also push 0x55 frames on FFF4; those are ignored).
    static func parse(_ b: [UInt8]) -> Frame? {
        guard b.count >= 18, b[0] == sof else { return nil }
        let total = Int(UInt16(b[1]) | (UInt16(b[2]) << 8)) & 0x3FF
        guard total == b.count else { return nil }
        guard crc16(b[0..<10]) == (UInt16(b[10]) | (UInt16(b[11]) << 8)) else { return nil }
        let c32 = UInt32(b[b.count - 4]) | (UInt32(b[b.count - 3]) << 8)
            | (UInt32(b[b.count - 2]) << 16) | (UInt32(b[b.count - 1]) << 24)
        guard crc32(b[0..<(b.count - 4)]) == c32 else { return nil }
        return Frame(cmdType: b[3], seq: UInt16(b[8]) | (UInt16(b[9]) << 8),
                     cmdSet: b[12], cmdId: b[13], data: Array(b[14..<(b.count - 4)]))
    }

    /// Splits a notification stream into frames. Frames may arrive glued or in
    /// pieces; anything that does not start with 0xAA is dropped up to the next
    /// 0xAA (the 0x55 status frames).
    struct Reassembler {
        private var buffer: [UInt8] = []

        mutating func feed(_ chunk: [UInt8]) -> [Frame] {
            buffer += chunk
            var out: [Frame] = []
            while !buffer.isEmpty {
                if buffer[0] != sof {
                    if let next = buffer.firstIndex(of: sof) { buffer.removeFirst(next) } else { buffer.removeAll() }
                    continue
                }
                guard buffer.count >= 3 else { break }
                let total = Int(UInt16(buffer[1]) | (UInt16(buffer[2]) << 8)) & 0x3FF
                guard total >= 18 else { buffer.removeFirst(); continue }
                guard buffer.count >= total else { break }
                let candidate = Array(buffer[0..<total])
                buffer.removeFirst(total)
                if let f = parse(candidate) { out.append(f) }
            }
            return out
        }
    }

    // MARK: Payloads (all little-endian, per DJI's protocol_data_segment.md)

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    /// 0x00/0x19 command: our identity + verification request.
    /// verifyMode 0 = the camera decides from its pairing history (pops a code
    /// if we are new), 1 = always pop the code. fwVersion 0 suppresses the
    /// firmware-update nag.
    static func connectionRequest(deviceId: UInt32, mac: [UInt8], verifyMode: UInt8, verifyData: UInt16) -> [UInt8] {
        var macField = Array(mac.prefix(16))
        macField += [UInt8](repeating: 0, count: 16 - macField.count)
        var out: [UInt8] = le32(deviceId)
        out.append(UInt8(mac.count))
        out += macField
        out += le32(0)                       // fw_version 0: no update nag
        out.append(0)                        // conidx
        out.append(verifyMode)
        out += le16(verifyData)
        out += [0, 0, 0, 0]
        return out
    }

    /// 0x00/0x19 ack to the camera's own connection request: device id, ret 0,
    /// reserved[0] = camera number (0 = single camera).
    static func connectionResponse(deviceId: UInt32) -> [UInt8] {
        var out: [UInt8] = le32(deviceId)
        out += [0, 0, 0, 0, 0]               // ret_code 0, reserved (camera number 0)
        return out
    }

    /// Fields of the camera's 0x00/0x19 request (verifyMode 2 carries the
    /// verdict in verifyData: 0 allowed, 1 rejected).
    static func parseConnectionRequest(_ d: [UInt8]) -> (deviceId: UInt32, verifyMode: UInt8, verifyData: UInt16)? {
        guard d.count >= 29 else { return nil }
        let id = UInt32(d[0]) | (UInt32(d[1]) << 8) | (UInt32(d[2]) << 16) | (UInt32(d[3]) << 24)
        return (id, d[26], UInt16(d[27]) | (UInt16(d[28]) << 8))
    }

    /// 0x1D/0x05: push mode 3 = periodic + on change, 20 = 2 Hz (the only rate allowed).
    static let statusSubscription: [UInt8] = [3, 20, 0, 0, 0, 0]

    /// 0x1D/0x03: 0 start, 1 stop.
    static func recordControl(deviceId: UInt32, start: Bool) -> [UInt8] {
        var out: [UInt8] = le32(deviceId)
        out += [start ? 0 : 1, 0, 0, 0, 0]
        return out
    }

    /// 0x1D/0x04: switch the shooting mode (0x01 = video).
    static func modeSwitch(deviceId: UInt32, mode: UInt8) -> [UInt8] {
        var out: [UInt8] = le32(deviceId)
        out += [mode, 0, 0, 0, 0]
        return out
    }

    /// 0x00/0x11: key report. keyCode 1 = record button, mode 1 = event, value 0 = short press.
    static func keyReport(keyCode: UInt8) -> [UInt8] { [keyCode, 1, 0, 0] }

    static let modeVideo: UInt8 = 0x01
    static let modePhoto: UInt8 = 0x05

    /// 0x1D/0x02 camera status push (the fields the race needs).
    struct StatusPush: Equatable {
        let cameraMode: UInt8
        /// 0 screen off, 1 live view, 2 playback, 3 recording / shooting, 5 pre-recording.
        let cameraStatus: UInt8
        let recordTimeSec: Int
        let remainCapacityMB: Int
        let remainTimeSec: Int
        /// 0 normal, 3 sleep.
        let powerMode: UInt8
        /// 0 ok, 1 warm (can record), 2 hot (cannot record), 3 overheating (shutting down).
        let tempOver: UInt8
        let batteryPercent: Int
        var isRecording: Bool { cameraStatus == 3 || cameraStatus == 5 }
        var isVideoMode: Bool { cameraMode == DJIProtocol.modeVideo || cameraMode == 0x28 || cameraMode == 0x00 }
    }

    static func parseStatus(_ d: [UInt8]) -> StatusPush? {
        guard d.count >= 38 else { return nil }
        func u16(_ i: Int) -> Int { Int(d[i]) | (Int(d[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { Int(d[i]) | (Int(d[i + 1]) << 8) | (Int(d[i + 2]) << 16) | (Int(d[i + 3]) << 24) }
        return StatusPush(
            cameraMode: d[0], cameraStatus: d[1], recordTimeSec: u16(5),
            remainCapacityMB: u32(15), remainTimeSec: u32(23),
            powerMode: d[28], tempOver: d[30], batteryPercent: Int(d[37]))
    }

    /// 0x1D/0x06 "new" status push: mode name + parameter as ASCII.
    static func parseModeName(_ d: [UInt8]) -> (name: String, param: String)? {
        guard d.count >= 23, d[0] == 0x01 else { return nil }
        let n = min(Int(d[1]), 20)
        let name = String(decoding: d[2..<(2 + n)], as: UTF8.self)
        var param = ""
        if d.count >= 25, d[23] == 0x02 {
            let m = min(Int(d[24]), 20, d.count - 25)
            param = String(decoding: d[25..<(25 + m)], as: UTF8.self)
        }
        return (name.trimmingCharacters(in: .whitespaces), param.trimmingCharacters(in: .whitespaces))
    }

    /// Model from the device id the camera sends in its connection request.
    static func modelName(deviceId: UInt32) -> String {
        switch deviceId {
        case 0xFF33: return "Osmo Action 4"
        case 0xFF44: return "Osmo Action 5 Pro"
        case 0xFF55: return "Osmo Action 6"
        case 0xFF66: return "Osmo 360"
        default: return String(format: "DJI 0x%X", deviceId)
        }
    }
}
