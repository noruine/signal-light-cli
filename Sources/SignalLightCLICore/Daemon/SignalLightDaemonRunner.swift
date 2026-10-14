import Dispatch
import Foundation
import SignalLightKit

/// The `run` subcommand's main loop — this is what launchd actually
/// executes. It never returns in the success path (only via SIGTERM/SIGINT,
/// handled below with a clean `exit(0)`); a crash or `kill -9` is what
/// launchd's `KeepAlive` catches and silently restarts.
enum SignalLightDaemonRunner {
    static func run(paths: SignalLightDaemonPaths) async throws {
        // The hook socket resolves against the *real* home, while `paths`
        // above honors `$HOME` (a
        // test/development affordance). launchd always runs with the real home;
        // a manually launched `HOME=… signal-light run` would otherwise check one
        // socket path and bind another, silently hijacking the real socket that
        // the agent hooks are using. Refuse loudly instead.
        let realHome = SignalLightDaemonPaths.systemHome().standardizedFileURL
        guard paths.home.standardizedFileURL == realHome else {
            throw CLIError(
                "当前 HOME 是 \(paths.home.path)，不是真实主目录 \(realHome.path)；"
                    + "launchd 和 Agent hooks 都使用真实主目录，两边会对不上。请去掉 HOME 覆盖后再启动服务。",
                exitCode: .config
            )
        }

        guard let device = try SignalLightStores.loadPairedDevice(from: paths.deviceJSONURL) else {
            throw CLIError("还没配对信号灯，请运行 signal-light pair。", exitCode: .noInput)
        }
        guard let deviceID = UUID(uuidString: device.identifier) else {
            throw CLIError("保存的设备信息已损坏，请重新配对：signal-light pair", exitCode: .config)
        }

        let log = RestrainedLog(url: paths.logURL)
        log.startFresh()
        log.log(.info, "daemon starting (paired device: \(device.name))")

        // MUST happen before `HookListener.start()`: it unlinks whatever
        // socket file already exists at this path before binding, so skipping
        // this check would let a fresh `run` silently hijack the socket a
        // still-running daemon of this same tool is using.
        if paths.ownedSockets.contains(where: SocketProbe.isActive) {
            throw CLIError(
                "检测到 bridge socket 仍在使用中（另一个守护进程在跑）。先停掉它：signal-light service stop。",
                exitCode: .unavailable
            )
        }

        let stateWriter = DaemonStateWriter(paths: paths)

        let bleDaemon = SignalLightBLEDaemon(pairedDeviceID: deviceID, log: log)
        bleDaemon.onStateChange = { state in
            switch state {
            case .unauthorized:
                stateWriter.updateBLE(.unauthorized, deviceName: nil)
            case .poweredOff:
                stateWriter.updateBLE(.poweredOff, deviceName: nil)
            case .disconnected:
                stateWriter.updateBLE(.disconnected, deviceName: nil)
            case .scanning:
                stateWriter.updateBLE(.scanning, deviceName: nil)
            case .connecting:
                stateWriter.updateBLE(.connecting, deviceName: nil)
            case let .connected(name):
                log.log(.info, "connected to signal light: \(name)")
                stateWriter.updateBLE(.connected, deviceName: name)
            }
        }
        bleDaemon.start()

        let controller = LightController(bleDaemon: bleDaemon, settingsURL: paths.settingsJSONURL, log: log)
        controller.reloadSettings()

        let registry = SessionRegistry()
        let hookListener = HookListener(socketURL: paths.bridgeSocketURL, registry: registry) { summary in
            controller.applyBucket(summary.bucket)
            stateWriter.updateSessionSummary(summary)
        }
        try await hookListener.start()
        log.log(.info, "hook socket listening")

        let shutdown = ShutdownCoordinator()
        let signalSources = installSignalHandlers(log: log, hookListener: hookListener, controller: controller, shutdown: shutdown)

        await shutdown.waitForShutdown()
        withExtendedLifetime(signalSources) {}
        exit(0)
    }

    /// Ignoring the default disposition before creating the dispatch source
    /// is required — otherwise the process could be torn down by the raw
    /// signal before the source ever gets to run its handler.
    ///
    /// SIGHUP is the live-reload signal: `config` sends it after editing
    /// settings so brightness/effects/on-off take effect without a restart
    /// (and without dropping the BLE connection).
    private static func installSignalHandlers(
        log: RestrainedLog,
        hookListener: HookListener,
        controller: LightController,
        shutdown: ShutdownCoordinator
    ) -> [DispatchSourceSignal] {
        var sources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                log.log(.info, "received shutdown signal, stopping cleanly")
                Task { await hookListener.stop() }
                shutdown.signalShutdown()
            }
            source.resume()
            return source
        }

        signal(SIGHUP, SIG_IGN)
        let reloadSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        reloadSource.setEventHandler {
            log.log(.info, "received SIGHUP, reloading settings")
            controller.reloadSettings()
        }
        reloadSource.resume()
        sources.append(reloadSource)

        return sources
    }
}

/// Owns the settings → effect/brightness → BLE mapping, so both the observer
/// loop (on session-state change) and the SIGHUP handler (on config change)
/// drive the light through one place. Thread-safe: the two callers run on
/// unrelated queues.
final class LightController: @unchecked Sendable {
    private let settingsURL: URL
    private let log: RestrainedLog
    private let sendDesiredState: @Sendable (Int, SignalLightEffect?) -> Void
    private let lock = NSLock()
    private var settings: SignalLightSettings = .default
    // Starts at `.idle` rather than `nil`: "no hook event has arrived yet"
    // means "no active sessions", and leaving it `nil` would send an explicit
    // OFF at startup instead of the idle effect.
    private var currentBucket: SignalLightBucket? = .idle

    init(bleDaemon: SignalLightBLEDaemon, settingsURL: URL, log: RestrainedLog) {
        self.settingsURL = settingsURL
        self.log = log
        sendDesiredState = { brightness, effect in
            bleDaemon.updateDesiredBrightness(brightness)
            bleDaemon.updateDesiredEffect(effect)
        }
    }

    init(
        settingsURL: URL,
        log: RestrainedLog,
        sendDesiredState: @escaping @Sendable (Int, SignalLightEffect?) -> Void
    ) {
        self.settingsURL = settingsURL
        self.log = log
        self.sendDesiredState = sendDesiredState
    }

    func applyBucket(_ bucket: SignalLightBucket) {
        lock.lock()
        defer { lock.unlock() }
        currentBucket = bucket
        let (brightness, effect) = resolveLocked()
        push(brightness: brightness, effect: effect)
    }

    /// Re-reads settings from disk and re-applies them to the current bucket.
    /// A malformed file is logged and ignored rather than crashing the daemon
    /// — the light keeps running on the last-good settings.
    func reloadSettings() {
        let loaded: SignalLightSettings
        do {
            loaded = try SignalLightStores.loadSettings(from: settingsURL)
        } catch {
            log.log(.warn, "failed to load settings, keeping current: \(error.localizedDescription)")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        settings = loaded
        let (brightness, effect) = resolveLocked()
        push(brightness: brightness, effect: effect)
    }

    /// Returns the brightness and the effect to show (nil ⇒ master switch off).
    private func resolveLocked() -> (Int, SignalLightEffect?) {
        let brightness = settings.clampedBrightness
        guard settings.enabled, let bucket = currentBucket else {
            return (brightness, nil)
        }
        return (brightness, settings.effect(for: bucket))
    }

    private func push(brightness: Int, effect: SignalLightEffect?) {
        sendDesiredState(brightness, effect)
    }
}

/// Bridges the signal-handler world (a synchronous `DispatchSource`
/// callback) to the `async` world (`run`'s suspension point), so the process
/// stays alive until a real shutdown signal arrives without a busy-wait loop.
private actor ShutdownCoordinator {
    private var continuation: CheckedContinuation<Void, Never>?
    private var shutdownRequested = false

    func waitForShutdown() async {
        if shutdownRequested { return }
        await withCheckedContinuation { continuation = $0 }
    }

    nonisolated func signalShutdown() {
        Task { await resume() }
    }

    private func resume() {
        shutdownRequested = true
        continuation?.resume()
        continuation = nil
    }
}

/// Merges BLE connection updates and bucket-resolution updates into the
/// single `state.json` snapshot `status` reads. The two arrive from
/// independent asynchronous sources (the BLE queue, and the bridge observer
/// loop) that must not race each other writing the same file.
final class DaemonStateWriter: @unchecked Sendable {
    private let paths: SignalLightDaemonPaths
    private let saveState: @Sendable (SignalLightDaemonState) -> Void
    private let lock = NSLock()
    /// Stamped into every snapshot so readers can tell a live daemon's state
    /// apart from the last snapshot a now-dead process left behind (the daemon
    /// never writes a final one on shutdown) — see `StatusSnapshot`.
    private let pid = Int(ProcessInfo.processInfo.processIdentifier)
    private var ble: SignalLightDaemonState.BLE = .disconnected
    private var deviceName: String?
    private var currentBucket: String?
    private var sessions: [SessionRegistry.SessionStatus]?

    init(
        paths: SignalLightDaemonPaths,
        saveState: (@Sendable (SignalLightDaemonState) -> Void)? = nil
    ) {
        self.paths = paths
        self.saveState = saveState ?? { state in
            try? SignalLightDaemonStateStore.save(state, to: paths.stateJSONURL)
        }
    }

    func updateBLE(_ state: SignalLightDaemonState.BLE, deviceName: String?) {
        lock.lock()
        defer { lock.unlock() }
        ble = state
        self.deviceName = deviceName
        persistLocked()
    }

    func updateSessionSummary(_ summary: SessionRegistry.Summary) {
        lock.lock()
        defer { lock.unlock() }
        currentBucket = summary.bucket.rawValue
        sessions = summary.sessions
        persistLocked()
    }

    private func persistLocked() {
        let snapshot = SignalLightDaemonState(
            ble: ble,
            deviceName: deviceName,
            currentBucket: currentBucket,
            sessions: sessions,
            updatedAt: Date(),
            pid: pid
        )
        saveState(snapshot)
    }
}
