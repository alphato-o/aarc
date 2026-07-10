import CoreBluetooth
import Foundation
import Observation

/// Battery level of the runner's Bluetooth earphones, for the in-run status
/// strip ("if I'm staring at the screen, might as well show something useful").
///
/// How: CoreBluetooth's GATT Battery Service (0x180F / level char 0x2A19).
/// `retrieveConnectedPeripherals` surfaces devices the SYSTEM already holds a
/// connection to (the earphones playing the coach audio); we open an app-level
/// session, read the level, and subscribe for changes. Honest limitation:
/// AirPods do not expose the GATT battery service to third-party apps, so this
/// shows nothing for them; most sport headsets (Shokz etc.) do expose it.
/// Scoped to the run screen: started on appear, stopped on disappear.
@MainActor
@Observable
final class EarpieceBattery: NSObject {
    static let shared = EarpieceBattery()

    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var level: Int   // 0-100
    }

    private(set) var devices: [Device] = []

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pollTask: Task<Void, Never>?
    private var active = false

    /// Begin watching. Safe to call repeatedly; first call triggers the
    /// system Bluetooth permission prompt.
    func start() {
        active = true
        // Journey/screenshot mode: the simulator has no Bluetooth at all, so
        // inject a deterministic mock device to prove the UI renders.
        if AppEnv.uiTest {
            devices = [Device(id: UUID(), name: "Mock Buds", level: 45)]
            return
        }
        if central == nil {
            // queue: .main so every delegate callback lands on the main
            // actor, matching this class's isolation.
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            refresh()
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Re-poll every 45s: catches newly connected earphones and
            // refreshes levels on devices that don't push notifications.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, self.active else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        active = false
        pollTask?.cancel()
        pollTask = nil
        if let central {
            for (_, p) in peripherals { central.cancelPeripheralConnection(p) }
        }
        peripherals.removeAll()
        devices.removeAll()
    }

    private func refresh() {
        guard let central, central.state == .poweredOn else { return }
        let found = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        // Telemetry: record what CoreBluetooth actually surfaced, so a run
        // where the row stays empty is diagnosable from the event log ("no
        // devices expose the battery service" vs "found but read failed").
        // Field context: Apple H1 earphones (AirPods / Powerbeats Pro) will
        // ALWAYS be absent here; their battery rides a private protocol.
        RunEventLog.shared.record(
            "earpiece.scan",
            found.isEmpty ? "no BLE peripherals expose battery service 0x180F"
                          : found.map { $0.name ?? "unnamed" }.joined(separator: " | "))
        for p in found {
            if peripherals[p.identifier] == nil {
                peripherals[p.identifier] = p
                p.delegate = self
                central.connect(p)
            } else if p.state == .connected {
                // Re-read on poll for devices that never notify.
                readBattery(p)
            }
        }
    }

    private func readBattery(_ p: CBPeripheral) {
        guard let s = p.services?.first(where: { $0.uuid == Self.batteryService }),
              let c = s.characteristics?.first(where: { $0.uuid == Self.batteryLevel })
        else { return }
        p.readValue(for: c)
    }

    private func upsert(_ p: CBPeripheral, level: Int) {
        let name = p.name ?? "Earphones"
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].level = level
            devices[i].name = name
        } else {
            devices.append(Device(id: p.identifier, name: name, level: level))
        }
    }
}

extension EarpieceBattery: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, active { refresh() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        peripherals[peripheral.identifier] = nil
        devices.removeAll { $0.id == peripheral.identifier }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else { return }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
        peripheral.readValue(for: c)
        peripheral.setNotifyValue(true, for: c)   // push updates when supported
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == Self.batteryLevel,
              let byte = characteristic.value?.first
        else { return }
        upsert(peripheral, level: Int(byte))
    }
}
