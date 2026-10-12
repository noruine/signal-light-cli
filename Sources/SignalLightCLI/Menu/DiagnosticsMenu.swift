
/// The 「诊断」 sub-page: the two read-only "something's off" tools. Kept one
/// level deep — each item is a single command, nothing nests further.
enum DiagnosticsMenu {
    static func run(terminal: Terminal) async {
        await MenuLoop.run(
            terminal: terminal,
            header: {
                terminal.out("\(terminal.emoji(CLIGlyph.doctor))诊断")
                terminal.out(terminal.dimmed("先体检定位问题，日志记录服务运行情况。"))
                terminal.out("")
            },
            buildItems: {
                [
                    MenuChoice("\(terminal.emoji(CLIGlyph.doctor))体检") {
                        await MenuCommandRunner.run(["doctor"], terminal: terminal)
                    },
                    MenuChoice("\(terminal.emoji(CLIGlyph.logs))查看最近日志") {
                        await MenuCommandRunner.run(["logs"], terminal: terminal)
                    },
                ]
            }
        )
    }
}
