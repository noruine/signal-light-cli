import ArgumentParser
import Foundation
import SignalLightKit

/// Updates an existing installation to the build this binary came from.
/// Runs the exact same steps as `install` (via the shared
/// `Installation.apply`) — the difference is the precondition and the
/// wording, not the machinery.
struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把本机安装升级到当前构建的版本。",
        discussion: """
        用当前这个二进制替换本机已安装的版本：配对、灯效配置、launchd
        设置一律保留；后台服务在运行的话自动重启以使用新版本。

        没装过时直接按安装处理。要升级到新代码：先把仓库更新到你要的
        版本（有远端就 git pull），再运行 make install——它构建当前
        代码并运行本命令。
        """
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        // Upgrading *from* the installed copy would replace it with itself;
        // only a fresh build has something new to install.
        guard !Installation.isRunningInstalledCopy(paths: paths) else {
            throw CLIError(
                "没有新构建可升级：当前运行的就是已安装的副本。先在仓库里运行 make build 构建，再用 .build/release/signal-light upgrade。",
                exitCode: .usage
            )
        }

        terminal.progress("\(terminal.emoji(CLIGlyph.upgrade))升级 signal-light 到当前构建…")

        let outcome = try Installation.apply(paths: paths, terminal: terminal)

        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success(outcome.wasInstalled ? "升级完成。" : "安装完成。"))")
        Installation.printSigningWarningIfNeeded(paths: paths, terminal: terminal)
    }
}
