import Combine
import CoreBluetooth
import Foundation

final class BLEVestManager: NSObject, ObservableObject {
    enum ConnectionState: String {
        case unavailable
        case disconnected
        case scanning
        case connecting
        case connected
        case failed

        var displayText: String {
            switch self {
            case .unavailable:
                return "Bluetooth unavailable"
            case .disconnected:
                return "Disconnected"
            case .scanning:
                return "Scanning"
            case .connecting:
                return "Connecting"
            case .connected:
                return "Connected"
            case .failed:
                return "Connection failed"
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var statusText = "BLE idle"
    @Published private(set) var connectedPeripheralName = "No vest connected"
    @Published private(set) var lastSendStatusText = "No BLE command sent"
    @Published private(set) var sentCommandCountText = "0"

    private let vestServiceUUID = CBUUID(string: AppConfig.BLE.vestServiceUUID)
    private let commandCharacteristicUUID = CBUUID(string: AppConfig.BLE.commandCharacteristicUUID)
    private var centralManager: CBCentralManager!
    private var vestPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var lastSendDate: Date?
    private var sentCommandCount = 0

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    var canSendCommands: Bool {
        connectionState == .connected
            && vestPeripheral != nil
            && commandCharacteristic != nil
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            connectionState = .unavailable
            statusText = bluetoothStateText
            return
        }

        commandCharacteristic = nil
        vestPeripheral = nil
        connectedPeripheralName = "No vest connected"
        connectionState = .scanning
        statusText = "Scanning for VisionVest vest"
        centralManager.scanForPeripherals(
            withServices: [vestServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func disconnect() {
        centralManager.stopScan()

        if let vestPeripheral {
            centralManager.cancelPeripheralConnection(vestPeripheral)
        }

        self.vestPeripheral = nil
        commandCharacteristic = nil
        connectionState = .disconnected
        connectedPeripheralName = "No vest connected"
        statusText = "BLE disconnected"
    }

    @discardableResult
    func send(message: VestMessage, bypassRateLimit: Bool = false) -> Bool {
        guard canSendCommands else {
            return false
        }

        guard bypassRateLimit || shouldSendNow() else {
            return false
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(message)
            send(data: data, seq: message.seq)
            return true
        } catch {
            lastSendStatusText = "BLE encode failed: \(error.localizedDescription)"
            return false
        }
    }

    private func send(data: Data, seq: Int) {
        guard let vestPeripheral,
              let commandCharacteristic else {
            return
        }

        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse

        vestPeripheral.writeValue(data, for: commandCharacteristic, type: writeType)
        lastSendDate = Date()
        sentCommandCount += 1
        sentCommandCountText = "\(sentCommandCount)"
        lastSendStatusText = "Sent BLE seq \(seq)"
    }

    private func shouldSendNow() -> Bool {
        guard let lastSendDate else {
            return true
        }

        return Date().timeIntervalSince(lastSendDate) >= AppConfig.BLE.minimumSendIntervalSeconds
    }

    private var bluetoothStateText: String {
        switch centralManager.state {
        case .unknown:
            return "Bluetooth state unknown"
        case .resetting:
            return "Bluetooth resetting"
        case .unsupported:
            return "Bluetooth unsupported"
        case .unauthorized:
            return "Bluetooth permission denied"
        case .poweredOff:
            return "Bluetooth is off"
        case .poweredOn:
            return "Bluetooth powered on"
        @unknown default:
            return "Bluetooth state unavailable"
        }
    }
}

extension BLEVestManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if connectionState == .unavailable {
                connectionState = .disconnected
            }
            statusText = "Bluetooth ready"
        default:
            connectionState = .unavailable
            statusText = bluetoothStateText
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        vestPeripheral = peripheral
        peripheral.delegate = self
        connectedPeripheralName = peripheral.name ?? "VisionVest Vest"
        connectionState = .connecting
        statusText = "Connecting to \(connectedPeripheralName)"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connecting
        statusText = "Discovering vest services"
        connectedPeripheralName = peripheral.name ?? "VisionVest Vest"
        peripheral.discoverServices([vestServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = .failed
        statusText = error.map { "BLE connect failed: \($0.localizedDescription)" } ?? "BLE connect failed"
        vestPeripheral = nil
        commandCharacteristic = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = .disconnected
        statusText = error.map { "BLE disconnected: \($0.localizedDescription)" } ?? "BLE disconnected"
        connectedPeripheralName = "No vest connected"
        vestPeripheral = nil
        commandCharacteristic = nil
    }
}

extension BLEVestManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectionState = .failed
            statusText = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == vestServiceUUID }) else {
            connectionState = .failed
            statusText = "Vest service not found"
            return
        }

        peripheral.discoverCharacteristics([commandCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            connectionState = .failed
            statusText = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }

        guard let characteristic = service.characteristics?.first(where: { $0.uuid == commandCharacteristicUUID }) else {
            connectionState = .failed
            statusText = "Command characteristic not found"
            return
        }

        commandCharacteristic = characteristic
        connectionState = .connected
        statusText = "Vest command channel ready"
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lastSendStatusText = "BLE write failed: \(error.localizedDescription)"
        }
    }
}
