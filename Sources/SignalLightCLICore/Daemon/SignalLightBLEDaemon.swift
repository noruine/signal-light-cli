@preconcurrency import CoreBluetooth
import Foundation
import SignalLightKit

enum BLEDiscoveryFailure {
    static func reason(error: String?, foundRequiredResource: Bool, resourceName: String) -> String? {
        if let error { return error }
        return foundRequiredResource ? nil : "未找到\(resourceName)"
    }
}

/// Headless BLE controller for the ESP32-C3 signal light — no UI, no
/// `@Observable`. All scan/connect/reconnect work runs on a private serial
/// queue instead of `.main`: `AsyncParsableCommand` blocks the main
/// thread's run loop while awaiting async work in `run`, so a `.main`-queued
/// `CBCentralManager` would never
/// actually get to deliver its delegate callbacks. All mutable state below
/// is confined to `queue` — either because a call came in via `queue.async`,
/// or because CoreBluetooth itself invokes delegate methods on `queue`
/// (passed as the manager's designated queue at init).
final class SignalLightBLEDaemon: NSObject, @unchecked Sendable {
    enum ConnectionState: Equatable {
        case unauthorized
        case poweredOff
        case disconnected
        case scanning
        case connecting
        case connected(name: String)
    }

    struct DiscoveredDevice: Sendable, Equatable {
        let name: String
        let id: UUID
    }

    /// The result of a one-shot `pair` scan. Distinguishes "scanned fine but
    /// found nothing" from the several ways Bluetooth itself can be
    /// unavailable — each needs a different message and next step, so they
    /// must never collapse into a single "未找到设备" error.
    enum ScanOutcome: Sendable {
        case found([DiscoveredDevice])
        /// The user stopped the scan from the keyboard — a normal way to end
        /// the wait, never an error.
        case cancelled
        case bluetoothOff
        case unauthorized
        case unsupported
    }

    /// Live phases a scan passes through, so the caller can animate real
    /// feedback instead of a frozen "(8s)" string.
    enum ScanPhase: Sendable {
        case waitingForBluetooth
        case scanning
        /// At least one device is in hand; the scan is now just briefly
        /// waiting to catch any others before returning. The countdown stops
        /// here — the user shouldn't have to wait out the full window once a
        /// light has already appeared.
        case finalizing
    }

    private let pairedDeviceID: UUID
    private let log: RestrainedLog
    private let queue = DispatchQueue(label: "app.signal-light.ble")

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    /// The effect to show, or `nil` meaning "master switch off → send OFF".
    private var desiredEffect: SignalLightEffect?
    private var desiredBrightness: Int?
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 1
    private var didWarnAboutAuthorization = false

    /// Invoked on `queue` whenever connection state changes. The caller
    /// (the daemon runner) is responsible for hopping to whatever context it
    /// needs — this type does not assume anything about who's listening.
    var onStateChange: ((ConnectionState) -> Void)?

    init(pairedDeviceID: UUID, log: RestrainedLog) {
        self.pairedDeviceID = pairedDeviceID
        self.log = log
    }

    func start() {
        queue.async { [self] in
            centralManager = CBCentralManager(delegate: self, queue: queue)
        }
    }

    /// Caches the effect to display (or `nil` for "off") and, if a device is
    /// already connected, sends it immediately. If not connected, it is sent
    /// as soon as the command characteristic becomes available (see
    /// `didDiscoverCharacteristicsFor`), so a reconnect always resyncs to
    /// current reality rather than leaving a stale effect showing.
    func updateDesiredEffect(_ effect: SignalLightEffect?) {
        queue.async { [self] in
            desiredEffect = effect
            sendDesiredEffectIfConnected()
        }
    }

    /// Caches the brightness and applies it immediately if connected;
    /// otherwise it is applied on the next (re)connect alongside the effect.
    func updateDesiredBrightness(_ percent: Int) {
        queue.async { [self] in
            desiredBrightness = percent
            sendBrightnessIfConnected()
        }
    }

    // MARK: - Connect / reconnect algorithm (queue-confined)

    private func attemptConnect() {
        guard let centralManager, centralManager.state == .poweredOn else { return }

        // The system remembers previously-connected peripherals by
        // identifier across launches — this is the fast, no-scan path that
        // covers the overwhelming majority of daemon (re)starts.
        if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [pairedDeviceID]).first {
            connect(to: peripheral)
            return
        }

        // Fallback for the rare case where this boot session doesn't yet
        // know the peripheral (e.g. right after pairing, before the system
        // cache is warm). Filtered by service UUID so we don't have to sift
        // through every BLE device in range.
        beginScan()
    }

    private func beginScan() {
        guard let centralManager else { return }
        onStateChange?(.scanning)
        centralManager.scanForPeripherals(withServices: [SignalLightBLESession.serviceUUID])

        let workItem = DispatchWorkItem { [weak self] in
            self?.handleScanTimeout()
        }
        scanTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func handleScanTimeout() {
        centralManager?.stopScan()
        scheduleReconnect()
    }

    private func connect(to peripheral: CBPeripheral) {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        centralManager?.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        onStateChange?(.connecting)
        centralManager?.connect(peripheral)
    }

    /// Exponential backoff (1s → 2s → … → capped at 30s), reset to 1s the
    /// moment a connection actually succeeds — this is what makes the
    /// daemon safe to leave running unattended without hammering the radio.
    private func scheduleReconnect() {
        guard reconnectWorkItem == nil else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.attemptConnect()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func sendDesiredEffectIfConnected() {
        let command = desiredEffect.map(SignalLightCommandEncoder.encode) ?? SignalLightControlCommand.off
        writeCommandIfConnected(command)
    }

    private func sendBrightnessIfConnected() {
        guard let percent = desiredBrightness else { return }
        writeCommandIfConnected(SignalLightControlCommand.brightness(percent: percent))
    }

    private func writeCommandIfConnected(_ command: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected else {
            return
        }
        peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withResponse)
    }

    // MARK: - One-shot scan for `pair` (no persistent state, independent instance)

    /// Starts the one-shot scan and returns the handle that can stop it
    /// early (see `SignalLightScanControl`). The handle may be dropped: the
    /// scan keeps itself alive until `completion` fires.
    @discardableResult
    static func scan(
        timeout: TimeInterval,
        maxBluetoothWait: TimeInterval = 60,
        graceAfterFirstFind: TimeInterval = 2,
        log: RestrainedLog,
        onPhase: @escaping (ScanPhase) -> Void = { _ in },
        completion: @escaping (ScanOutcome) -> Void
    ) -> SignalLightScanControl {
        // `CBCentralManager.delegate` is `weak`, so the scanner would die as
        // soon as this function returns — and with it every delegate
        // callback, including `completion`. The handle retains the scanner,
        // the completion closure retains the handle, and the pair is released
        // together when the scan finishes (`release`).
        let handle = SignalLightScanControl()
        let scanner = SignalLightBLEScanner(
            timeout: timeout,
            maxBluetoothWait: maxBluetoothWait,
            graceAfterFirstFind: graceAfterFirstFind,
            log: log,
            onPhase: onPhase
        ) { outcome in
            completion(outcome)
            handle.release()
        }
        handle.adopt(scanner)
        scanner.start()
        return handle
    }
}

extension SignalLightBLEDaemon: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectDelay = 1
            attemptConnect()
        case .unauthorized:
            onStateChange?(.unauthorized)
            if !didWarnAboutAuthorization {
                didWarnAboutAuthorization = true
                log.log(.warn, "蓝牙未授权，请在 系统设置 → 隐私与安全性 → 蓝牙 里允许后重试。")
            }
        case .poweredOff:
            onStateChange?(.poweredOff)
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
        guard peripheral.identifier == pairedDeviceID else { return }
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([SignalLightBLESession.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        failConnection(reason: error?.localizedDescription ?? "未知错误")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        failConnection(reason: error?.localizedDescription ?? "连接已断开")
    }

    private func failConnection(reason: String) {
        log.log(.warn, "信号灯连接失败：\(reason)")
        connectedPeripheral = nil
        commandCharacteristic = nil
        onStateChange?(.disconnected)
        scheduleReconnect()
    }

    private func failDiscovery(_ peripheral: CBPeripheral, reason: String) {
        centralManager?.cancelPeripheralConnection(peripheral)
        failConnection(reason: reason)
    }
}

extension SignalLightBLEDaemon: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let service = peripheral.services?.first(where: { $0.uuid == SignalLightBLESession.serviceUUID })
        if let reason = BLEDiscoveryFailure.reason(
            error: error?.localizedDescription,
            foundRequiredResource: service != nil,
            resourceName: "信号灯服务"
        ) {
            failDiscovery(peripheral, reason: reason)
            return
        }
        guard let service else { return }
        peripheral.discoverCharacteristics([SignalLightBLESession.commandCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let characteristic = service.characteristics?.first(where: { $0.uuid == SignalLightBLESession.commandCharacteristicUUID })
        if let reason = BLEDiscoveryFailure.reason(
            error: error?.localizedDescription,
            foundRequiredResource: characteristic != nil,
            resourceName: "控制特征"
        ) {
            failDiscovery(peripheral, reason: reason)
            return
        }
        guard let characteristic else { return }
        commandCharacteristic = characteristic
        reconnectDelay = 1
        onStateChange?(.connected(name: peripheral.name ?? "Signal Light"))
        // Brightness before effect so the very first frame the device shows
        // is already at the configured level, not a flash at the old one.
        sendBrightnessIfConnected()
        sendDesiredEffectIfConnected()
    }
}

/// Handle for a one-shot scan: lets the pairing flow's keyboard watcher stop
/// an in-flight scan, and keeps the scan alive until it finishes. `cancel`
/// after a natural finish is a no-op.
final class SignalLightScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var scanner: SignalLightBLEScanner?

    fileprivate init() {}

    fileprivate func adopt(_ scanner: SignalLightBLEScanner) {
        lock.lock()
        self.scanner = scanner
        lock.unlock()
    }

    /// Drops the scanner once the scan ended, releasing the self-owning
    /// cycle that kept it alive until now.
    fileprivate func release() {
        lock.lock()
        scanner = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let scanner = scanner
        lock.unlock()
        scanner?.cancel()
    }
}

/// Independent, short-lived scanner used only by `signal-light pair` — it
/// never connects, just discovers service-matching peripherals for the user
/// to choose from. Kept fully separate from `SignalLightBLEDaemon` so the
/// long-running daemon's reconnect state machine can't be affected by a
/// concurrently-running `pair` invocation (they're always different
/// processes in practice, but this also keeps the two responsibilities from
/// becoming entangled in-process).
private final class SignalLightBLEScanner: NSObject, @unchecked Sendable, CBCentralManagerDelegate {
    private let timeout: TimeInterval
    private let maxBluetoothWait: TimeInterval
    private let graceAfterFirstFind: TimeInterval
    private let log: RestrainedLog
    private let onPhase: (SignalLightBLEDaemon.ScanPhase) -> Void
    private let completion: (SignalLightBLEDaemon.ScanOutcome) -> Void
    private let queue = DispatchQueue(label: "app.signal-light.ble.scan")

    private var centralManager: CBCentralManager?
    private var discovered: [UUID: SignalLightBLEDaemon.DiscoveredDevice] = [:]
    private var didFinish = false
    private var didStartScan = false
    private var didAnnounceWaiting = false
    private var didScheduleGraceFinish = false
    private var bluetoothGiveUpWorkItem: DispatchWorkItem?
    private var scanTimeoutWorkItem: DispatchWorkItem?

    init(
        timeout: TimeInterval,
        maxBluetoothWait: TimeInterval,
        graceAfterFirstFind: TimeInterval,
        log: RestrainedLog,
        onPhase: @escaping (SignalLightBLEDaemon.ScanPhase) -> Void,
        completion: @escaping (SignalLightBLEDaemon.ScanOutcome) -> Void
    ) {
        self.timeout = timeout
        self.maxBluetoothWait = maxBluetoothWait
        self.graceAfterFirstFind = graceAfterFirstFind
        self.log = log
        self.onPhase = onPhase
        self.completion = completion
    }

    /// Ends the scan early from any thread: the radio stops and the
    /// completion fires with `.cancelled`. A no-op once finished.
    func cancel() {
        queue.async { [self] in
            finish(.cancelled)
        }
    }

    func start() {
        queue.async { [self] in
            centralManager = CBCentralManager(delegate: self, queue: queue)
        }
    }

    private func finish(_ outcome: SignalLightBLEDaemon.ScanOutcome) {
        guard !didFinish else { return }
        didFinish = true
        bluetoothGiveUpWorkItem?.cancel()
        scanTimeoutWorkItem?.cancel()
        centralManager?.stopScan()
        completion(outcome)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScanning(central)
        case .poweredOff:
            // Not fatal: macOS has no public API to power the radio on, so
            // instead of failing we tell the caller to prompt the user and
            // keep the manager alive — the moment they enable Bluetooth this
            // fires again with `.poweredOn` and the scan starts automatically.
            // A bounded give-up timer prevents hanging forever if they don't.
            announceWaitingIfNeeded()
        case .unauthorized:
            log.log(.warn, "蓝牙未授权。")
            finish(.unauthorized)
        case .unsupported:
            log.log(.warn, "这台设备不支持蓝牙。")
            finish(.unsupported)
        case .unknown, .resetting:
            break  // transient — CoreBluetooth will call again shortly
        @unknown default:
            break
        }
    }

    private func announceWaitingIfNeeded() {
        guard !didAnnounceWaiting else { return }
        didAnnounceWaiting = true
        onPhase(.waitingForBluetooth)

        let workItem = DispatchWorkItem { [weak self] in
            self?.finish(.bluetoothOff)
        }
        bluetoothGiveUpWorkItem = workItem
        queue.asyncAfter(deadline: .now() + maxBluetoothWait, execute: workItem)
    }

    private func beginScanning(_ central: CBCentralManager) {
        guard !didStartScan else { return }  // ignore repeat poweredOn notifications
        didStartScan = true
        bluetoothGiveUpWorkItem?.cancel()
        bluetoothGiveUpWorkItem = nil

        onPhase(.scanning)
        central.scanForPeripherals(withServices: [SignalLightBLESession.serviceUUID])

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.found(Array(self.discovered.values)))
        }
        scanTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discovered[peripheral.identifier] = SignalLightBLEDaemon.DiscoveredDevice(
            name: peripheral.name ?? "Signal Light",
            id: peripheral.identifier
        )

        // First device in hand: no reason to make the user wait out the full
        // window. Replace the long timeout with a short grace period to catch
        // any second light, then return. (Grace can be 0, meaning "return
        // immediately on first find".)
        guard !didScheduleGraceFinish else { return }
        didScheduleGraceFinish = true
        scanTimeoutWorkItem?.cancel()
        onPhase(.finalizing)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.found(Array(self.discovered.values)))
        }
        scanTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + graceAfterFirstFind, execute: workItem)
    }
}
