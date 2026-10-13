import Foundation
import SignalLightKit

/// The 「诊断」 sub-page: the "something's off" tools, one level deep — each
/// item is a single command. Doctor locates problems; status and the log tail
/// report what the light is doing; the file inventory keeps uninstalls honest;
/// and the signing setup is where a rebuild's Bluetooth permission gets fixed
/// (re-signing changes the binary's code identity, so it lives here).
enum DiagnosticsMenu {
    static func run(terminal: Terminal) async {
        await MenuLoop.run(
            terminal: terminal,
            header: {
                terminal.out("\(terminal.emoji(CLIGlyph.doctor))诊断")
                if FileManager.default.fileExists(atPath: SignalLightDaemonPaths.current().binURL.path) {
                    terminal.out(terminal.dimmed("版本 \(AppVersion.current())"))
                }
                terminal.out("")
            },
            buildItems: {
                [
                    MenuChoice("\(terminal.emoji(CLIGlyph.doctor))体检") {
                        await MenuCommandRunner.run(["doctor"], terminal: terminal)
                    },
                    MenuChoice("\(terminal.emoji(CLIGlyph.trafficLight))查看当前状态") {
                        await MenuCommandRunner.run(["status"], terminal: terminal)
                    },
                    MenuChoice("\(terminal.emoji(CLIGlyph.logs))查看最近日志") {
                        await MenuCommandRunner.run(["logs"], terminal: terminal)
                    },
                    MenuChoice("\(terminal.emoji(CLIGlyph.search))查看文件清单") {
                        await MenuCommandRunner.run(["audit"], terminal: terminal)
                    },
                    MenuChoice("\(terminal.emoji(CLIGlyph.signing))配置固定签名") {
                        await MenuCommandRunner.run(["sign"], terminal: terminal)
                    },
                ]
            }
        )
    }
}
