import ArgumentParser
import Foundation
import SignalLightKit

struct Rename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "查看或修改信号灯的蓝牙名称（不带参数则只查看）。"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "新的蓝牙名称；省略则只显示当前名称。")
    var newName: String?

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        guard let device = try SignalLightStores.loadPairedDevice(from: paths.deviceJSONURL),
              let deviceID = UUID(uuidString: device.identifier) else {
            throw CLIError(ContextText.choose(cli: "还没配对，请运行 signal-light pair。", menu: "还没配对。"), exitCode: .noInput)
        }

        let control = LaunchAgentControl(paths: paths)
        try await DaemonPause.run(terminal: terminal, control: control) {
            let session = SignalLightBLESession(pairedDeviceID: deviceID)
            terminal.progress("\(terminal.emoji(CLIGlyph.search))正在连接信号灯…")
            try await session.connect()
            defer { session.disconnect() }

            let currentName = (try? await session.getConfig())?.name
            if let currentName {
                terminal.out("当前蓝牙名称：\(currentName)")
            }

            guard let newName = newName?.trimmingCharacters(in: .whitespaces), !newName.isEmpty else {
                return  // Read-only mode: nothing more to do.
            }

            try await applyRename(newName, session: session, deviceID: deviceID, paths: paths, terminal: terminal)
        }
    }

    private func applyRename(
        _ newName: String,
        session: SignalLightBLESession,
        deviceID: UUID,
        paths: SignalLightDaemonPaths,
        terminal: Terminal
    ) async throws {
        terminal.out("新名称：\(newName)")
        if terminal.isInteractive {
            guard Confirm.promptYesNo(terminal, "设备将自动重启，确认？", defaultAnswer: false) else {
                terminal.out("已取消。")
                return
            }
        }

        try await session.sendCommand(SignalLightControlCommand.setName(newName))

        // The firmware reboots right after applying the name, so a confirming
        // notification may or may not arrive before the link drops — treat a
        // timeout as "probably succeeded, device is rebooting" rather than a
        // hard failure, matching the Python tool's behavior.
        let confirmed = (try? await session.awaitNotification(prefix: nil, timeout: 5))?.lowercased().contains("ok") ?? false

        // The CoreBluetooth identifier is stable across a BLE-name change, so
        // the paired device's UUID stays valid; only the display name updates.
        let updated = SignalLightPairedDevice(name: newName, identifier: deviceID.uuidString)
        try? SignalLightDeviceStore.save(updated, to: paths.deviceJSONURL)

        if confirmed {
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已修改，设备正在重启。"))")
        } else {
            terminal.out("\(terminal.emoji(CLIGlyph.success))指令已发出，设备重启后名称变为 “\(newName)”。")
        }
    }
}
