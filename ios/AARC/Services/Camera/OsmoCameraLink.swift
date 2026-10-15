import CoreBluetooth
import Foundation
import Observation

/// BLE link to a DJI Osmo Action camera, speaking DJI's remote-controller
/// protocol (see `DJIProtocol`). One camera, one link. The phone is the
/// central; the camera advertises service FFF0 and keeps the pairing on its
/// side once the runner has confirmed the code on its screen.
///
/// Lifecycle: `activate()` finds and holds the camera (scan on first use,
/// direct connect by identifier afterwards), runs the handshake, subscribes
/// to the 2 Hz status push and keeps reconnecting until `deactivate()`. A
/// battery swap is a disconnect followed by a reconnect to the same
/// identifier, which CoreBluetooth retries for us without a timeout.
///
/// Callbacks land on the main queue (`queue: .main`), matching this class's
/// isolation, the same pattern as `EarpieceBattery`.
@MainActor
@Observable
final class OsmoCameraLink: NSObject {
    static let shared = OsmoCameraLink()

    enum State: String {
        case off, bluetoothOff, scanning, connecting, handshaking, awaitingConfirm, connected, offline, rejected
        var isConnected: Bool { self == .connected }
    }

    struct Snapshot: Equatable {
        var model: String?
        var batteryPercent: Int?
        var isRecording = false
        var isVideoMode: Bool?
        var modeName: String?
        var modeParam: String?
        var recordTimeSec = 0
        var remainTimeSec: Int?
        var tempOver = 0
        var isAsleep = false
        var updatedAt = Date.distantPast

        var summary: String {
            var parts: [String] = []
            if let b = batteryPercent { parts.append("\(b)%") }
            parts.append(isRecording ? "REC \(recordTimeSec / 60)m" : "idle")
            if let m = modeName, !m.isEmpty { parts.append(m) } else if isVideoMode == false { parts.append("not video") }
            if isAsleep { parts.append("asleep") }
            if tempOver >= 2 { parts.append("HOT") }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    enum Event { case state(State), status(Snapshot), ack(key: String, ok: Bool) }

    private(set) var state: State = .off
    private(set) var snapshot: Snapshot?
    private(set) var lastError: String?
    private(set) var peripheralName: String?
    private(set) var lastConnectedAt: Date?
    private(set) var disconnectedAt: Date?
    /// The director hangs its policy here; Settings leaves it nil.
    var observer: ((Event) -> Void)?

    // Persistent identity: the camera remembers (deviceId, verifyData) as the
    // paired remote, so these never change once a pairing succeeded.
    private static let kDeviceId = "aarc.camera.deviceId"
    private static let kVerifyData = "aarc.camera.verifyData"
    private static let kPaired = "aarc.camera.paired"
    private static let kPeripheral = "aarc.camera.peripheralId"
    private static let kName = "aarc.camera.name"
    static let kEnabled = "aarc.camera.enabled"
    /// Registered when a run starts in race mode and from Settings; default on.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: kEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: kEnabled) }
    }

    private var deviceId: UInt32 {
        if let v = UserDefaults.standard.object(forKey: Self.kDeviceId) as? UInt32, v != 0 { return v }
        let v = UInt32.random(in: 0x1000_0000...0xEFFF_FFFF)
        UserDefaults.standard.set(v, forKey: Self.kDeviceId)
        return v
    }
    private var verifyData: UInt16 {
        if let v = UserDefaults.standard.object(forKey: Self.kVerifyData) as? UInt16, v != 0 { return v }
        let v = UInt16.random(in: 1000...60000)
        UserDefaults.standard.set(v, forKey: Self.kVerifyData)
        return v
    }
    var isPaired: Bool { UserDefaults.standard.bool(forKey: Self.kPaired) }
    var knownName: String? { UserDefaults.standard.string(forKey: Self.kName) }
    /// The protocol-level MAC we present; any stable 6 bytes will do.
    private let mac: [UInt8] = [0x38, 0x34, 0x56, 0x78, 0x9A, 0xBC]

    private static let service = CBUUID(string: "FFF0")
    private static let notifyChar = CBUUID(string: "FFF4")
    private static let writeChar = CBUUID(string: "FFF5")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var reassembler = DJIProtocol.Reassembler()
    private var seq: UInt16 = UInt16.random(in: 1...1000)
    private var active = false
    private var handshakeTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var candidates: [UUID: (CBPeripheral, Int)] = [:]

    // MARK: - Control

    /// Find and hold the camera. Safe to call repeatedly.
    func activate() {
        active = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            connectOrScan()
        }
    }

    /// Drop the link and stop reconnecting. The pairing is kept.
    func deactivate() {
        active = false
        scanTask?.cancel(); scanTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        writeCharacteristic = nil
        setState(.off)
    }

    /// Forget the pairing; the next activate scans and asks the camera again.
    func forget() {
        deactivate()
        for k in [Self.kPaired, Self.kPeripheral, Self.kName, Self.kVerifyData] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        snapshot = nil
        peripheralName = nil
    }

    func startRecording() { send(set: 0x1D, id: 0x03, DJIProtocol.recordControl(deviceId: deviceId, start: true)) }
    func stopRecording() { send(set: 0x1D, id: 0x03, DJIProtocol.recordControl(deviceId: deviceId, start: false)) }
    func switchToVideo() { send(set: 0x1D, id: 0x04, DJIProtocol.modeSwitch(deviceId: deviceId, mode: DJIProtocol.modeVideo)) }
    /// A short press of the shutter, whatever the mode (DJI's recommended control).
    func pressShutter() { send(set: 0x00, id: 0x11, DJIProtocol.keyReport(keyCode: 0x01)) }

    // MARK: - Connection

    private func setState(_ s: State) {
        guard state != s else { return }
        state = s
        if s == .connected { lastConnectedAt = .now; disconnectedAt = nil }
        if s == .offline, disconnectedAt == nil { disconnectedAt = .now }
        observer?(.state(s))
    }

    private func connectOrScan() {
        guard active, let central, central.state == .poweredOn else { return }
        if let stored = UserDefaults.standard.string(forKey: Self.kPeripheral), let id = UUID(uuidString: stored),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        startScan()
    }

    private func startScan() {
        guard let central else { return }
        candidates = [:]
        setState(.scanning)
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            // Give the strongest camera 4 s to show up, then take it. A
            // scan that finds nothing keeps running until deactivate().
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.active, self.state == .scanning else { return }
            if let best = self.candidates.values.max(by: { $0.1 < $1.1 })?.0 {
                self.central?.stopScan()
                self.connect(best)
            }
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        peripheralName = p.name
        setState(.connecting)
        central?.connect(p, options: nil)
    }

    private func beginHandshake() {
        guard writeCharacteristic != nil else { return }
        reassembler = DJIProtocol.Reassembler()
        setState(.handshaking)
        // verifyMode 0: the camera checks its own pairing list and pops the
        // code only for a remote it does not know. Matches DJI's test frames.
        let payload = DJIProtocol.connectionRequest(deviceId: deviceId, mac: mac, verifyMode: 0, verifyData: verifyData)
        send(set: 0x00, id: 0x19, payload, type: DJIProtocol.cmdWaitResult)
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            // The camera answers within a second; its own request follows
            // at once for a known remote, or after the runner confirms the
            // code on the screen (give him a full minute in the corral).
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if self.state == .handshaking { self.setState(.awaitingConfirm) }
            try? await Task.sleep(for: .seconds(57))
            guard !Task.isCancelled, self.state == .awaitingConfirm || self.state == .handshaking else { return }
            self.lastError = "camera did not complete the handshake"
            RunEventLog.shared.record("camera.link", "handshake timed out; retrying")
            self.reconnectLater()
        }
    }

    private func reconnectLater() {
        guard active, let p = peripheral else { return }
        central?.cancelPeripheralConnection(p)
        // didDisconnect re-issues connect(); nothing else to do here.
    }

    private func send(set: UInt8, id: UInt8, _ payload: [UInt8], type: UInt8 = DJIProtocol.cmdResponseOrNot, seq forced: UInt16? = nil) {
        guard let p = peripheral, let c = writeCharacteristic, p.state == .connected else { return }
        let s: UInt16
        if let forced { s = forced } else { seq &+= 1; s = seq }
        let bytes = DJIProtocol.frame(cmdSet: set, cmdId: id, cmdType: type, payload: payload, seq: s)
        p.writeValue(Data(bytes), for: c, type: .withoutResponse)
    }

    private func handle(_ f: DJIProtocol.Frame) {
        switch (f.key, f.isAck) {
        case ("0019", true):
            // Our connection request was heard. ret_code sits after device_id.
            if f.data.count >= 5, f.data[4] != 0 {
                lastError = "camera refused the connection (code \(f.data[4]))"
                RunEventLog.shared.record("camera.link", lastError ?? "")
            }
        case ("0019", false):
            guard let req = DJIProtocol.parseConnectionRequest(f.data) else { return }
            if req.verifyMode == 2, req.verifyData == 0 {
                send(set: 0x00, id: 0x19, DJIProtocol.connectionResponse(deviceId: deviceId), type: DJIProtocol.ack, seq: f.seq)
                handshakeTask?.cancel(); handshakeTask = nil
                UserDefaults.standard.set(true, forKey: Self.kPaired)
                if let p = peripheral {
                    UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.kPeripheral)
                    UserDefaults.standard.set(p.name ?? "Osmo", forKey: Self.kName)
                }
                var snap = snapshot ?? Snapshot()
                snap.model = DJIProtocol.modelName(deviceId: req.deviceId)
                snapshot = snap
                lastError = nil
                setState(.connected)
                RunEventLog.shared.record("camera.link", "connected to \(snap.model ?? "camera")")
                send(set: 0x1D, id: 0x05, DJIProtocol.statusSubscription)
            } else {
                lastError = "camera rejected the pairing"
                UserDefaults.standard.set(false, forKey: Self.kPaired)
                RunEventLog.shared.record("camera.link", lastError ?? "")
                setState(.rejected)
                handshakeTask?.cancel(); handshakeTask = nil
                if let p = peripheral { central?.cancelPeripheralConnection(p) }
            }
        case ("1D02", false):
            guard let st = DJIProtocol.parseStatus(f.data) else { return }
            var snap = snapshot ?? Snapshot()
            snap.batteryPercent = st.batteryPercent
            snap.isRecording = st.isRecording
            snap.isVideoMode = st.isVideoMode
            snap.recordTimeSec = st.recordTimeSec
            snap.remainTimeSec = st.remainTimeSec
            snap.tempOver = Int(st.tempOver)
            snap.isAsleep = st.powerMode == 3
            snap.updatedAt = .now
            snapshot = snap
            observer?(.status(snap))
        case ("1D06", false):
            guard let m = DJIProtocol.parseModeName(f.data) else { return }
            var snap = snapshot ?? Snapshot()
            snap.modeName = m.name
            snap.modeParam = m.param
            snapshot = snap
        case ("1D03", true), ("1D04", true), ("0011", true):
            let ok = f.data.first == 0
            if !ok { RunEventLog.shared.record("camera.nack", "\(f.key) ret \(f.data.first ?? 255)") }
            observer?(.ack(key: f.key, ok: ok))
        default:
            break
        }
    }
}

extension OsmoCameraLink: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectOrScan()
        case .unauthorized: lastError = "Bluetooth permission denied"; setState(.bluetoothOff)
        case .poweredOff: setState(.bluetoothOff)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // DJI cameras: name "Osmo…" and manufacturer id 0x08AA.
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let isDJI = name.lowercased().hasPrefix("osmo") || (mfg.map { $0.count >= 2 && $0[0] == 0xAA && $0[1] == 0x08 } ?? false)
        guard isDJI else { return }
        candidates[peripheral.identifier] = (peripheral, RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheralName = peripheral.name
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        lastError = error?.localizedDescription
        guard active else { return }
        setState(.offline)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        writeCharacteristic = nil
        handshakeTask?.cancel(); handshakeTask = nil
        guard active else { setState(.off); return }
        if state != .rejected {
            setState(.offline)
            RunEventLog.shared.record("camera.link", "disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
        // A pending connect survives the camera being off for a battery
        // swap: CoreBluetooth completes it when the camera advertises again.
        central.connect(peripheral, options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            lastError = "camera has no DJI service"; reconnectLater(); return
        }
        peripheral.discoverCharacteristics([Self.notifyChar, Self.writeChar], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let chars = service.characteristics,
              let n = chars.first(where: { $0.uuid == Self.notifyChar }),
              let w = chars.first(where: { $0.uuid == Self.writeChar }) else {
            lastError = "camera characteristics missing"; reconnectLater(); return
        }
        writeCharacteristic = w
        peripheral.setNotifyValue(true, for: n)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == Self.notifyChar, characteristic.isNotifying else { return }
        beginHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == Self.notifyChar, let data = characteristic.value else { return }
        for frame in reassembler.feed([UInt8](data)) { handle(frame) }
    }
}
