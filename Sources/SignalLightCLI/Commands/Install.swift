import ArgumentParser
import Foundation
import SignalLightKit

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把 signal-light 安装到本机。",
        discussion: """
        安装只做机器侧的事：复制程序、准备 hooks 组件、建好命令。
        更新已经装过的版本用 signal-light upgrade；配对、灯效配置与
        launchd 设置一律保留，运行中的后台服务会自动重启。

        其余步骤用安装好的命令按需执行：

          signal-light pair             配对你的红绿灯
          signal-light service start    启动后台服务（首次自动登记）
          signal-light hooks install    接入 Agent（会让你选 Claude 还是 Codex）
        """
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        terminal.progress("\(terminal.emoji(CLIGlyph.package))安装 signal-light 到本机…")

        try Installation.apply(paths: paths, terminal: terminal)

        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("安装完成。"))")

        if !pathContainsSymlinkDir(paths) {
            terminal.out("")
            terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("~/.local/bin 不在 PATH 里，现在还运行不了 signal-light。"))")
            terminal.out("    \(shellPathHint())")
        }

        terminal.out("")
        terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("首次连接信号灯时，macOS 会弹窗请求蓝牙权限，点「允许」。"))")
        Installation.printSigningWarningIfNeeded(paths: paths, terminal: terminal)

        // In a guided menu session the menu itself walks the user through the
        // next steps (pair → start → …) as offers, so this typed-command
        // checklist would just be dangling, disconnected instructions.
        guard !CLIRuntimeContext.isMenuSession else { return }

        terminal.out("")
        terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))运行 signal-light 打开菜单。")
        terminal.out("    命令行用法：signal-light --help")
    }

    private func pathContainsSymlinkDir(_ paths: SignalLightDaemonPaths) -> Bool {
        let standardizedTarget = paths.pathSymlinkDir.standardizedFileURL.path
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return searchPaths.contains { URL(fileURLWithPath: String($0)).standardizedFileURL.path == standardizedTarget }
    }

    /// fish has a first-class, persistent way to do this (`fish_add_path`)
    /// that isn't "editing a config file" in the fragile sense — it's the
    /// shell's own supported mechanism, so it gets top billing; everyone
    /// else still needs one line added to their rc file by hand.
    private func shellPathHint() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if shell.hasSuffix("fish") {
            return "执行一次即可永久生效：fish_add_path ~/.local/bin"
        }
        return "在你的 shell 配置文件里加一行：export PATH=\"$HOME/.local/bin:$PATH\""
    }
}
