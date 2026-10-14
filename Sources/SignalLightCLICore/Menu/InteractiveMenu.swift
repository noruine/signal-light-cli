import Foundation
import SignalLightKit

/// The interactive menu bare `signal-light` drops into. Every item is a thin
/// wrapper around a real subcommand (`MenuCommandRunner`) or a one-level
/// sub-page — the menu owns no business logic, only which items make sense
/// given the current state.
///
/// The list has the same rows in every service state, so nothing a user is
/// aiming at ever moves: one contextual slot at the top carries the next
/// setup step (install → pair → start) and, once the service exists, becomes
/// the 「服务」 page that holds stop / restart / autostart.
enum InteractiveMenu {
    static func run(terminal: Terminal) async {
        let paths = SignalLightDaemonPaths.current()

        await MenuScreenBuffer.withAlternateBuffer {
            await MenuLoop.run(
                terminal: terminal,
                escapeHint: .escape("退出"),
                refreshInterval: 1,
                context: {
                    let snapshot = StatusSnapshot.current(paths: paths)
                    var lines = snapshot.menuHeaderLines(terminal: terminal)
                    if let hint = nextStepHint(paths: paths, snapshot: snapshot) {
                        lines.append("\(terminal.emoji(CLIGlyph.next))\(hint)")
                    }
                    return lines
                },
                buildItems: {
                    let snapshot = StatusSnapshot.current(paths: paths)
                    let state = MenuState(paths: paths, snapshot: snapshot)
                    return buildItems(state: state, snapshot: snapshot, paths: paths, terminal: terminal)
                }
            )
        }
    }

    /// One-line "here's where you are" nudge shown above the list until the
    /// light is up and running and at least one agent is wired up. Written as
    /// plain spoken Chinese — the current situation, in someone's own words —
    /// so it never reads like a restatement of the menu item below it.
    private static func nextStepHint(paths: SignalLightDaemonPaths, snapshot: StatusSnapshot) -> String? {
        let state = MenuState(paths: paths, snapshot: snapshot)
        if !state.toolInstalled { return "还没安装到本机" }
        if !state.paired { return "还没配对信号灯" }
        if !snapshot.serviceIsRunning { return "服务未启动，灯不会亮" }
        if !state.anyHooksInstalled { return "还没接入 Agent；接入后灯会随会话状态变色" }
        return nil
    }

    private static func buildItems(
        state: MenuState,
        snapshot: StatusSnapshot,
        paths: SignalLightDaemonPaths,
        terminal: Terminal
    ) -> [MenuChoice] {
        var items: [MenuChoice] = []

        // The one contextual slot at the top: install → pair → start, and —
        // once the service exists — the 「服务」 page (stop / restart /
        // autostart). What matters is that the slot *always exists* in these
        // states: it used to grow from one row into three the moment the
        // service started, pushing every row below it down a slot and
        // renumbering the list under the user's cursor.
        if !state.toolInstalled {
            items.append(MenuChoice("\(terminal.emoji(CLIGlyph.package))安装到本机", crumb: "安装到本机") {
                await MenuCommandRunner.run(["upgrade"], terminal: terminal)
            })
        } else if snapshot.jobInfo.isLoaded || state.serviceRegistered {
            // Registered (or running) means there is something to control, even
            // if the device file went missing — the page must stay reachable.
            items.append(MenuChoice("\(terminal.emoji(CLIGlyph.trafficLight))服务", crumb: "服务", pausesAfter: false) {
                await ServiceMenu.run(terminal: terminal)
            })
        } else if !state.paired {
            items.append(MenuChoice("\(terminal.emoji(CLIGlyph.device))配对设备", crumb: "配对设备") {
                await MenuCommandRunner.run(["pair"], terminal: terminal)
            })
        } else {
            items.append(MenuChoice("\(terminal.emoji(CLIGlyph.start))启动服务", crumb: "启动服务") {
                await MenuCommandRunner.run(["service", "start"], terminal: terminal)
            })
        }

        items.append(MenuChoice("\(terminal.emoji(CLIGlyph.effect))灯效设置", crumb: "灯效设置", pausesAfter: false) {
            await ConfigMenu.run(terminal: terminal)
        })
        items.append(MenuChoice("\(terminal.emoji(CLIGlyph.agent))接入 Agent", crumb: "接入 Agent", pausesAfter: false) {
            await HooksMenu.run(terminal: terminal)
        })
        items.append(MenuChoice("\(terminal.emoji(CLIGlyph.device))设备管理", crumb: "设备管理", pausesAfter: false) {
            await DeviceMenu.run(terminal: terminal)
        })
        items.append(MenuChoice("\(terminal.emoji(CLIGlyph.doctor))诊断", crumb: "诊断", pausesAfter: false) {
            await DiagnosticsMenu.run(terminal: terminal)
        })

        if state.toolInstalled {
            items.append(MenuChoice("\(terminal.emoji(CLIGlyph.upgrade))升级", crumb: "升级") {
                await MenuCommandRunner.run(["upgrade"], terminal: terminal)
            })
            items.append(MenuChoice(
                "\(terminal.emoji(CLIGlyph.cleanup))卸载",
                crumb: "卸载",
                shouldExitAfter: { !FileManager.default.fileExists(atPath: paths.binURL.path) }
            ) {
                await MenuCommandRunner.run(["uninstall"], terminal: terminal)
            })
        }

        return items
    }
}

/// The setup progress of the tool on this machine, read fresh each menu loop
/// so items reflect reality after any action. The three axes are independent
/// on purpose (you can be installed-but-unpaired, paired-but-not-started, …)
/// — matching the now-decoupled `install` / `pair` / `service start` steps.
private struct MenuState {
    let toolInstalled: Bool
    let paired: Bool
    let serviceRegistered: Bool
    let anyHooksInstalled: Bool

    init(paths: SignalLightDaemonPaths, snapshot: StatusSnapshot) {
        toolInstalled = FileManager.default.fileExists(atPath: paths.binURL.path)
        paired = (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL)) != nil
        serviceRegistered = LaunchAgentControl(paths: paths).currentRunAtLoad() != nil
        anyHooksInstalled = HookAgent.allCases.contains {
            (try? HooksAgentSupport.status($0, paths: paths))?.managedHooksPresent ?? false
        }
    }
}
