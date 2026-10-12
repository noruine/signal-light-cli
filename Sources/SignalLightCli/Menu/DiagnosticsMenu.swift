
/// The 「诊断」 sub-page: the two read-only "something's off" tools. Kept one
/// level deep — each item is a single command, nothing nests further.
enum DiagnosticsMenu {
    static func run(terminal: Terminal) async {
        await MenuLoop.run(
            terminal: terminal,
            header: {
                terminal.out("\(terminal.emoji(CLIGlyph.doctor))诊断")
                terminal.out(terminal.dimmed("哪儿不对先体检，日志能看出服务在忙什么。"))
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
