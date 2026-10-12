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

    @Flag(help: "自动选择扫描到的第一个设备。")
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
        let progress = ScanProgress(terminal: terminal)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<SignalLightBLEDaemon.ScanOutcome, Never>) in
            SignalLightBLEDaemon.scan(
                timeout: timeout,
                log: log,
                onPhase: { phase in
                    switch phase {
                    case .waitingForBluetooth: progress.waitingForBluetooth()
                    case .scanning: progress.scanning(seconds: timeout)
                    case .finalizing: progress.finalizing()
                    }
                },
                completion: { continuation.resume(returning: $0) }
            )
        }
        progress.finish()

        let discovered: [SignalLightBLEDaemon.DiscoveredDevice]
        switch outcome {
        case let .found(devices):
            discovered = devices
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
                "未找到信号灯。请确认设备已通电、距离不太远，或延长扫描时间：signal-light pair --timeout 120",
                exitCode: .unavailable
            )
        }

        guard let chosen = try selectDevice(from: discovered, terminal: terminal, device: device, first: first) else {
            CancelNotice.say("已取消配对。", terminal: terminal)
            return
        }

        let paired = SignalLightPairedDevice(name: chosen.name, identifier: chosen.id.uuidString)
        try SignalLightDeviceStore.save(paired, to: paths.deviceJSONURL)

        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("配对成功：\(chosen.name)。"))")
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
            terminal.progress("    接下来：signal-light service start 启动服务")
        }
    }

    private static func selectDevice(
        from discovered: [SignalLightBLEDaemon.DiscoveredDevice],
        terminal: Terminal,
        device: String?,
        first: Bool
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
            return discovered[0]
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
            footerHint: "↑/↓ 移动 · 回车确认 · Esc 取消",
            header: {
                terminal.out("\(terminal.emoji(CLIGlyph.search))找到 \(discovered.count) 个设备，选择要配对的：")
                terminal.out("")
            }
        )
        guard case let .selected(index) = outcome else {
            return nil  // backed out of the picker; not an error
        }
        return discovered[index]
    }
}
