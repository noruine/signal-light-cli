import SignalLightKit

/// The 「服务」 sub-page: start / stop / restart and login autostart.
///
/// These used to be top-level rows that appeared — and pushed every other row
/// down a slot (renumbering the whole list) — the moment the service started.
/// Keeping them in a page leaves the main list the same shape in every service
/// state, with the entry itself as the one contextual first row.
enum ServiceMenu {
    static func run(terminal: Terminal) async {
        let paths = SignalLightDaemonPaths.current()

        await MenuLoop.run(
            terminal: terminal,
            header: {
                let snapshot = StatusSnapshot.current(paths: paths)
                terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))服务")
                terminal.out(terminal.dimmed("状态：\(snapshot.menuServiceDescription)"))
                terminal.out("")
            },
            buildItems: {
                let snapshot = StatusSnapshot.current(paths: paths)
                var items: [MenuChoice] = []

                if snapshot.serviceIsRunning {
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.stop))停止服务") {
                        await MenuCommandRunner.run(["service", "stop"], terminal: terminal)
                    })
                } else {
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.start))启动服务") {
                        await MenuCommandRunner.run(["service", "start"], terminal: terminal)
                    })
                }

                if snapshot.jobInfo.isLoaded {
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.restart))重启服务") {
                        await MenuCommandRunner.run(["service", "restart"], terminal: terminal)
                    })
                }

                if snapshot.runAtLoad != nil {
                    // Imperative phrasing ("开启/关闭") — the status line above
                    // already shows the current autostart state, so restating
                    // it here would read as the action's outcome instead of
                    // what selecting it does.
                    let autostartOn = snapshot.runAtLoad == true
                    items.append(MenuChoice("\(terminal.emoji(CLIGlyph.autostart))\(autostartOn ? "关闭" : "开启")开机自启") {
                        await MenuCommandRunner.run(
                            ["service", "autostart", autostartOn ? "disable" : "enable"],
                            terminal: terminal
                        )
                    })
                }

                return items
            }
        )
    }
}
