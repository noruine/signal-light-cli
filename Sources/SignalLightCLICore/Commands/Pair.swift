import ArgumentParser
import Foundation
import SignalLightKit

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "扫描并配对红绿灯设备（只扫描，不建立长连接）。"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(help: "扫描超时时间（秒）；找到设备会提前结束，此值只是上限。")
    var timeout: Double = 60

    @Option(help: "按名称或 UUID 直接选择设备，跳过交互式列表。")
    var device: String?

    @Flag(help: "只在扫到唯一设备时自动选择；扫到多个会列出来让你指定。")
    var first: Bool = false

    func run() async throws {
        try await PairFlow.run(terminal: globals.makeTerminal(), paths: .current(), timeout: timeout, device: device, first: first)
    }
}

/// The pairing flow behind the `Pair` command, kept as its own type so the
/// command body stays a thin argv shim and the flow can be driven directly.
enum PairFlow {
    static func run(
        terminal: Terminal,
        paths: SignalLightDaemonPaths,
        timeout: Double,
        device: String?,
        first: Bool
    ) async throws {
        let log = RestrainedLog(url: paths.logURL)
        // Breadcrumbs are menu chrome: inside the menu the result screen
        // already prints it (and the picker continues that trail); a bare
        // CLI run stays Unix-plain and shows none.
        let menuTrail = CLIRuntimeContext.menuTrail
        let pickerTrail: [String]? = CLIRuntimeContext.isMenuSession
            ? (menuTrail.isEmpty ? ["配对设备"] : menuTrail)
            : nil
        let progress = ScanProgress(terminal: terminal)

        let outcome = try await runScan(timeout: timeout, log: log, progress: progress, terminal: terminal)
        progress.finish()
        // Keys pressed while the scan ran (nothing was reading them) must
        // not answer the device picker that may follow; drop them once.
        RawMode.discardPendingInput()

        let discovered: [SignalLightBLEDaemon.DiscoveredDevice]
        switch outcome {
        case let .found(devices):
            discovered = devices
        case .cancelled:
            CancelNotice.say("已取消配对。", terminal: terminal)
            return
        case .bluetoothOff:
            throw CLIError("蓝牙未开启。请打开蓝牙后重新配对。", exitCode: .unavailable)
        case .unauthorized:
            throw CLIError(
                "蓝牙未授权。请在 系统设置 → 隐私与安全性 → 蓝牙 里允许后重试。",
                exitCode: .unavailable
            )
        case .unsupported:
            throw CLIError("这台电脑没有蓝牙，无法连接信号灯。", exitCode: .unavailable)
        }

        guard !discovered.isEmpty else {
            throw CLIError(
                "没有找到信号灯。请确认设备已通电、距离不太远，或延长扫描时间：signal-light pair --timeout 120",
                exitCode: .unavailable
            )
        }

        guard let chosen = try selectDevice(from: discovered, terminal: terminal, device: device, first: first, trail: pickerTrail) else {
            CancelNotice.say("已取消配对。", terminal: terminal)
            return
        }

        let paired = SignalLightPairedDevice(name: chosen.name, identifier: chosen.id.uuidString)
        try SignalLightDeviceStore.save(paired, to: paths.deviceJSONURL)

        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已配对 “\(chosen.name)”。"))")
        // A running daemon resolved its device at startup, so a re-pair only
        // takes effect after a restart — say so, or the light silently keeps
        // driving the old hardware.
        if LaunchAgentControl(paths: paths).jobInfo().isLoaded {
            terminal.progress(CLIRuntimeContext.isMenuSession
                ? "    换设备之后要重启服务才生效。"
                : "    换设备之后要重启服务才生效：signal-light service restart")
        } else if !CLIRuntimeContext.isMenuSession {
            // In a guided menu session the menu offers the next step
            // interactively; only the bare-CLI path needs the typed hint.
            terminal.progress(ContextText.choose(
                cli: "    服务还没启动：运行 signal-light service start",
                menu: "    服务还没启动。"
            ))
        }
    }

    /// Runs the one-shot scan, arming the terminal's stop keys when there is
    /// a keyboard to listen to: Esc (or Ctrl-C, like every other cancel here)
    /// ends the wait the same way backing out of the device picker does — as
    /// `.cancelled`, printed as the usual one-line cancel. A scan can take a
    /// minute, and watching it with no way out is the worst part of pairing.
    private static func runScan(
        timeout: Double,
        log: RestrainedLog,
        progress: ScanProgress,
        terminal: Terminal
    ) async throws -> SignalLightBLEDaemon.ScanOutcome {
        let onPhase: @Sendable (SignalLightBLEDaemon.ScanPhase) -> Void = { phase in
            switch phase {
            case .waitingForBluetooth: progress.waitingForBluetooth()
            case .scanning: progress.scanning(seconds: timeout)
            case .finalizing: progress.finalizing()
            }
        }

        guard terminal.isInteractive else {
            return await withCheckedContinuation { continuation in
                SignalLightBLEDaemon.scan(
                    timeout: timeout,
                    log: log,
                    onPhase: onPhase,
                    completion: { continuation.resume(returning: $0) }
                )
            }
        }

        let handle = ScanCancelHandle()
        return try await withThrowingTaskGroup(of: SignalLightBLEDaemon.ScanOutcome.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let control = SignalLightBLEDaemon.scan(
                        timeout: timeout,
                        log: log,
                        onPhase: onPhase,
                        completion: { continuation.resume(returning: $0) }
                    )
                    handle.adopt(control)
                }
            }
            group.addTask {
                await waitForScanCancelKey()
                handle.cancel()
                return .cancelled
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    /// Blocks while the scan runs: returns once any interrupt key arrives
    /// — the same set the pickers cancel on — or when this task is cancelled
    /// because the scan finished on its own. The caller treats the two exits
    /// identically (cancelling a finished scan is a no-op), so nothing is
    /// reported back.
    private static func waitForScanCancelKey() async {
        guard let original = RawMode.enter(interceptingInterrupts: true) else {
            // No keys readable after all: sit still until the scan files its
            // result and the task group cancels this one.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            return
        }
        defer { RawMode.restore(original) }
        _ = try? await waitForInterruptKey()
    }

    private static func selectDevice(
        from discovered: [SignalLightBLEDaemon.DiscoveredDevice],
        terminal: Terminal,
        device: String?,
        first: Bool,
        trail: [String]?
    ) throws -> SignalLightBLEDaemon.DiscoveredDevice? {
        if let device {
            guard let match = discovered.first(where: {
                $0.name.localizedCaseInsensitiveContains(device) || $0.id.uuidString.localizedCaseInsensitiveContains(device)
            }) else {
                throw CLIError("没找到叫 “\(device)” 的设备。", exitCode: .unavailable)
            }
            return match
        }

        if first {
            // A scan can see a neighbor's light. Taking "the first one" then
            // would drive hardware someone else owns — only act when there is
            // exactly one candidate, and otherwise make the user name it.
            guard discovered.count == 1, let only = discovered.first else {
                let names = discovered.map(\.name).joined(separator: "、")
                throw CLIError(
                    "扫到 \(discovered.count) 个信号灯：\(names)。请用 --device <名称或 UUID> 指定。",
                    exitCode: .usage
                )
            }
            return only
        }

        guard terminal.isInteractive else {
            throw CLIError("无法在此选择（非交互环境）。请用 --device 或 --first 指定设备。", exitCode: .usage)
        }

        // Same arrow-key picker as every other selection in this CLI, so
        // choosing a device feels identical to choosing a menu item — no
        // switching between "type a number" and "press arrows."
        let labels = discovered.map { "\($0.name)  \(terminal.dimmed($0.id.uuidString))" }
        let outcome = MenuSelector.choose(
            items: labels,
            terminal: terminal,
            trail: trail,
            context: {
                ["找到 \(discovered.count) 个设备，选择要配对的："]
            },
            footerHint: terminal.keyBar([.move, .enter("确认"), .escape("取消")])
        )
        guard case let .selected(index) = outcome else {
            return nil  // backed out of the picker; not an error
        }
        return discovered[index]
    }
}

/// Bridges the scan's control handle between the two racing tasks: the scan
/// task creates the handle once the scan starts, the key watcher cancels
/// through it. A cancel that arrives before the handle exists is remembered
/// and applied when it does.
private final class ScanCancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var control: SignalLightScanControl?
    private var cancelRequested = false

    func adopt(_ control: SignalLightScanControl) {
        lock.lock()
        self.control = control
        let cancelRequested = cancelRequested
        lock.unlock()
        if cancelRequested {
            control.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let control = control
        lock.unlock()
        control?.cancel()
    }
}


/// Forgets the paired light. The service is stopped first: a running daemon
/// would otherwise keep driving a device the user just walked away from.
struct Unpair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpair",
        abstract: "忘掉已配对的红绿灯（会先停下后台服务）。"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()
        let control = LaunchAgentControl(paths: paths)

        if control.jobInfo().isLoaded {
            terminal.progress("先停下后台服务…")
            await control.bootoutAndWait()
        }

        guard FileManager.default.fileExists(atPath: paths.deviceJSONURL.path) else {
            terminal.out("本来就没配对。")
            return
        }
        try FileManager.default.removeItem(at: paths.deviceJSONURL)
        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已忘掉配对设备。重新配对：signal-light pair"))")
    }
}
