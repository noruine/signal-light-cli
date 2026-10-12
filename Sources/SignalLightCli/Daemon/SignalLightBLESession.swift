@preconcurrency import CoreBluetooth
import Foundation
import SignalLightKit

enum SignalLightSessionError: Error, CustomStringConvertible {
    case bluetoothUnavailable(String)
    case deviceNotFound
    case connectFailed(String)
    case notReady
    case timedOut(String)
    case firmwareRejected(String)

    var description: String {
        switch self {
        case let .bluetoothUnavailable(detail): detail
        case .deviceNotFound: "未找到信号灯。请确认设备已通电、距离不太远。"
        case let .connectFailed(detail): "蓝牙连接失败：\(detail)"
        case .notReady: "设备未就绪（缺少蓝牙特征）。"
        case let .timedOut(what): "等待\(what)超时。"
        case let .firmwareRejected(status): "设备没接受：\(status)"
        }
    }
}

/// One-shot request/response BLE client for interactive maintenance
/// operations — calibration, firmware flashing, rename. Deliberately separate
/// from `SignalLightBLEDaemon`, which only ever pushes effects and never reads
/// replies: this type connects to one paired peripheral, exposes async
/// command/notification/read primitives, and disconnects when the caller is
/// done.
///
/// The ESP32 firmware accepts a single BLE connection at a time, so callers
/// MUST free the background daemon's connection first (see `DaemonPause`).
///
/// All mutable state is confined to `queue`, which is also the
/// `CBCentralManager`'s delegate queue — so delegate callbacks and the async
/// primitives below never race. Every `await` boundary hops back onto `queue`
/// before touching state.
final class SignalLightBLESession: NSObject, @unchecked Sendable {
    static let serviceUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000001")
    static let commandCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000002")
    static let otaControlCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000003")
    static let otaDataCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000004")
    static let infoCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000005")

    private let targetID: UUID
    private let queue = DispatchQueue(label: "app.signal-light.session")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var otaControlChar: CBCharacteristic?
    private var otaDataChar: CBCharacteristic?
    private var infoChar: CBCharacteristic?

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var scanTimeout: DispatchWorkItem?

    /// Notifications on the OTA-control characteristic arriving before anyone
    /// is awaiting them (the firmware can push `CONFIG:`/OTA status between
    /// our `await`s). Buffered so `awaitNotification` never misses one.
    private var notificationBuffer: [String] = []
    private var pendingNotification: (prefix: String?, continuation: CheckedContinuation<String, Error>, timeout: DispatchWorkItem)?

    /// At most one outstanding write per characteristic, since every caller
    /// awaits its write's ack before issuing the next.
    private var pendingWrites: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingInfoRead: CheckedContinuation<String, Error>?

    init(pairedDeviceID: UUID) {
        self.targetID = pairedDeviceID
    }

    var hasOTACharacteristics: Bool {
        queue.sync { otaDataChar != nil && otaControlChar != nil }
    }

    /// Largest payload the peripheral accepts in one acked write, floored at
    /// 20 (the BLE default MTU) so we always send at least a minimal chunk.
    var maxWriteChunkSize: Int {
        queue.sync {
            guard let peripheral else { return 20 }
            return max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        }
    }

    // MARK: - Connection

    func connect(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                connectContinuation = continuation
                central = CBCentralManager(delegate: self, queue: queue)
                scanTimeout = scheduleTimeout(after: timeout) { [weak self] in
                    self?.failConnect(SignalLightSessionError.timedOut("连接设备"))
                }
            }
        }
    }

    func disconnect() {
        queue.sync {
            if let peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            central?.stopScan()
        }
    }

    // MARK: - Primitives

    /// Writes to the command characteristic and awaits the write ack.
    func sendCommand(_ text: String) async throws {
        try await write(Data(text.utf8), characteristic: Self.commandCharacteristicUUID)
    }

    func sendControl(_ text: String) async throws {
        try await write(Data(text.utf8), characteristic: Self.otaControlCharacteristicUUID)
    }

    func sendData(_ chunk: Data) async throws {
        try await write(chunk, characteristic: Self.otaDataCharacteristicUUID)
    }

    /// Reads the INFO characteristic (firmware version / hardware id).
    func readInfo(timeout: TimeInterval = 5) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                guard let peripheral, let infoChar else {
                    continuation.resume(throwing: SignalLightSessionError.notReady)
                    return
                }
                pendingInfoRead = continuation
                peripheral.readValue(for: infoChar)
                // A dropped read would otherwise hang forever; bound it.
                let work = scheduleTimeout(after: timeout) { [weak self] in
                    guard let self, let pending = self.pendingInfoRead else { return }
                    self.pendingInfoRead = nil
                    pending.resume(throwing: SignalLightSessionError.timedOut("读取设备信息"))
                }
                _ = work
            }
        }
    }

    /// Awaits the next OTA-control notification whose text starts with
    /// `prefix` (or any notification when `prefix` is nil), draining the
    /// buffer first so an early-arriving reply is never lost.
    func awaitNotification(prefix: String?, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                if let index = notificationBuffer.firstIndex(where: { prefix == nil || $0.hasPrefix(prefix!) }) {
                    let text = notificationBuffer.remove(at: index)
                    continuation.resume(returning: text)
                    return
                }
                let work = scheduleTimeout(after: timeout) { [weak self] in
                    guard let self, let pending = self.pendingNotification else { return }
                    self.pendingNotification = nil
                    pending.continuation.resume(throwing: SignalLightSessionError.timedOut("设备响应"))
                }
                pendingNotification = (prefix, continuation, work)
            }
        }
    }

    /// Sends `GETCONFIG` and parses the resulting `CONFIG:` notification into
    /// the device's current pin mapping + BLE name.
    func getConfig(timeout: TimeInterval = 5) async throws -> SignalLightDeviceConfig {
        try await sendCommand(SignalLightControlCommand.getConfig)
        let text = try await awaitNotification(prefix: "CONFIG:", timeout: timeout)
        guard let config = SignalLightConfigDecoder.decode(text) else {
            throw SignalLightSessionError.firmwareRejected(text)
        }
        return config
    }

    // MARK: - Internal write plumbing

    private func write(_ data: Data, characteristic uuid: CBUUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let peripheral, let characteristic = characteristic(for: uuid) else {
                    continuation.resume(throwing: SignalLightSessionError.notReady)
                    return
                }
                pendingWrites[uuid] = continuation
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    private func characteristic(for uuid: CBUUID) -> CBCharacteristic? {
        switch uuid {
        case Self.commandCharacteristicUUID: commandChar
        case Self.otaControlCharacteristicUUID: otaControlChar
        case Self.otaDataCharacteristicUUID: otaDataChar
        default: nil
        }
    }

    private func scheduleTimeout(after seconds: TimeInterval, _ handler: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: handler)
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }

    private func failConnect(_ error: Error) {
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(throwing: error)
    }

    private func succeedConnect() {
        scanTimeout?.cancel()
        scanTimeout = nil
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume()
    }
}

extension SignalLightBLESession: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let peripheral = central.retrievePeripherals(withIdentifiers: [targetID]).first {
                connect(to: peripheral, central: central)
            } else {
                central.scanForPeripherals(withServices: [Self.serviceUUID])
            }
        case .unauthorized:
            failConnect(SignalLightSessionError.bluetoothUnavailable("蓝牙未授权，请在 系统设置 → 隐私与安全性 → 蓝牙 里允许。"))
        case .poweredOff:
            failConnect(SignalLightSessionError.bluetoothUnavailable("蓝牙未开启，请打开后重试。"))
        case .unsupported:
            failConnect(SignalLightSessionError.bluetoothUnavailable("这台设备不支持蓝牙低功耗。"))
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripheral.identifier == targetID else { return }
        central.stopScan()
        connect(to: peripheral, central: central)
    }

    private func connect(to peripheral: CBPeripheral, central: CBCentralManager) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        failConnect(SignalLightSessionError.connectFailed(error?.localizedDescription ?? "未知错误"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        // Surface an unexpected drop to whatever is currently awaiting, so a
        // mid-operation disconnect fails fast instead of hanging on a timeout.
        let dropped = SignalLightSessionError.connectFailed("连接已断开")
        failConnect(dropped)
        if let pending = pendingNotification {
            pendingNotification = nil
            pending.timeout.cancel()
            pending.continuation.resume(throwing: dropped)
        }
        for (_, continuation) in pendingWrites {
            continuation.resume(throwing: dropped)
        }
        pendingWrites.removeAll()
        if let pending = pendingInfoRead {
            pendingInfoRead = nil
            pending.resume(throwing: dropped)
        }
    }
}

extension SignalLightBLESession: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failConnect(SignalLightSessionError.notReady)
            return
        }
        peripheral.discoverCharacteristics(
            [
                Self.commandCharacteristicUUID,
                Self.otaControlCharacteristicUUID,
                Self.otaDataCharacteristicUUID,
                Self.infoCharacteristicUUID,
            ],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.commandCharacteristicUUID: commandChar = characteristic
            case Self.otaControlCharacteristicUUID:
                otaControlChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.otaDataCharacteristicUUID: otaDataChar = characteristic
            case Self.infoCharacteristicUUID: infoChar = characteristic
            default: break
            }
        }

        // Command + OTA-control are the baseline every operation needs (the
        // firmware reports CONFIG and OTA status over the control channel).
        // OTA-data/INFO are validated per-operation by the caller.
        guard commandChar != nil, otaControlChar != nil else {
            failConnect(SignalLightSessionError.notReady)
            return
        }
        succeedConnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let continuation = pendingWrites.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, let value = characteristic.value, let text = String(data: value, encoding: .utf8) else {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if characteristic.uuid == Self.infoCharacteristicUUID {
            guard let pending = pendingInfoRead else { return }
            pendingInfoRead = nil
            pending.resume(returning: trimmed)
            return
        }

        guard characteristic.uuid == Self.otaControlCharacteristicUUID else { return }

        if let pending = pendingNotification, pending.prefix == nil || trimmed.hasPrefix(pending.prefix!) {
            pendingNotification = nil
            pending.timeout.cancel()
            pending.continuation.resume(returning: trimmed)
        } else {
            notificationBuffer.append(trimmed)
        }
    }
}
