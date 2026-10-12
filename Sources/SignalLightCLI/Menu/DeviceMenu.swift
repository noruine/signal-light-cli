import SignalLightKit

/// The 「设备管理」 sub-page: everything hardware-facing that isn't part of
/// daily light operation — pairing, renaming, wiring calibration, firmware.
/// Grouped here instead of scattered across the main menu so the daily items
/// stay short.
enum DeviceMenu {
    static func run(terminal: Terminal) async {
        let paths = SignalLightDaemonPaths.current()

        await MenuLoop.run(
            terminal: terminal,
            header: {
                let deviceName = (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL))?.name
                terminal.out("\(terminal.emoji(CLIGlyph.device))设备管理")
                terminal.out(terminal.dimmed(deviceName.map { "当前：\($0)" } ?? "还没配对过设备"))
                terminal.out("")
            },
            buildItems: {
                var items: [MenuChoice] = [
                    MenuChoice("\(terminal.emoji(CLIGlyph.search))重新扫描并配对") {
                        await MenuCommandRunner.run(["pair"], terminal: terminal)
                    },
                ]

                if (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL)) != nil {
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.rename))重命名蓝牙名称", pausesAfter: false) {
                        await renameDevice(paths: paths, terminal: terminal)
                    })
                }

                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.calibrate))接线校准") {
                    await MenuCommandRunner.run(["calibrate"], terminal: terminal)
                })
                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.firmware))固件更新（检查并升级）") {
                    await MenuCommandRunner.run(["firmware", "update"], terminal: terminal)
                })

                return items
            }
        )
    }

    /// Prompts with the current name as the default so a bare Enter is a
    /// harmless no-op; renaming to the same name never touches the device.
    /// Pauses only when something was shown — cancelling with Esc returns to
    /// the list instantly.
    private static func renameDevice(paths: SignalLightDaemonPaths, terminal: Terminal) async {
        let current = (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL))?.name
        guard let name = MenuPrompt.text("新的蓝牙名称", default: current), !name.isEmpty else { return }
        guard name != current else {
            terminal.out("名称没有变化。")
            MenuPrompt.pause(terminal)
            return
        }
        await MenuCommandRunner.run(["rename", name], terminal: terminal)
        MenuPrompt.pause(terminal)
    }
}
