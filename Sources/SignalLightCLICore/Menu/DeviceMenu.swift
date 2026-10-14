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
            page: "设备管理",
            context: {
                let deviceName = (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL))?.name
                return [deviceName.map { "当前：\($0)" } ?? "还没配对过设备"]
            },
            buildItems: {
                let paired = (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL)) != nil
                var items: [MenuChoice] = [
                    MenuChoice("\(terminal.emoji(CLIGlyph.search))重新扫描并配对", crumb: "重新扫描并配对") {
                        await MenuCommandRunner.run(["pair"], terminal: terminal)
                    },
                ]

                if paired {
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.rename))重命名蓝牙名称", crumb: "重命名蓝牙名称", pausesAfter: false) {
                        await renameDevice(paths: paths, terminal: terminal)
                    })
                }

                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.calibrate))接线校准", crumb: "接线校准") {
                    await MenuCommandRunner.run(["calibrate"], terminal: terminal)
                })
                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.firmware))固件更新", crumb: "固件更新") {
                    await MenuCommandRunner.run(["firmware", "update"], terminal: terminal)
                })

                if paired {
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.unpair))忘掉已配对设备", crumb: "忘掉已配对设备") {
                        await MenuCommandRunner.run(["unpair"], terminal: terminal)
                    })
                }

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
        guard let name = MenuPrompt.text("新的蓝牙名称", default: current, terminal: terminal), !name.isEmpty else { return }
        guard name != current else {
            terminal.out("名称没有变化。")
            MenuPrompt.pause(terminal)
            return
        }
        await MenuCommandRunner.run(["rename", name], terminal: terminal)
        MenuPrompt.pause(terminal)
    }
}
