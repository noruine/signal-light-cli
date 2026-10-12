import ArgumentParser
import Foundation
import SignalLightKit

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把 signal-light 安装到本机（复制程序、准备 hooks 组件、建好命令），不启动任何东西。",
        discussion: """
        install 只让 signal-light 命令在本机可用（一次性），不启动任何东西。
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

        try installBinary(paths: paths, terminal: terminal)
        try linkIntoPath(paths: paths, terminal: terminal)
        installHooksBinary(paths: paths, terminal: terminal)

        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("装好，直接敲 signal-light 就行。"))")

        if !pathContainsSymlinkDir(paths) {
            terminal.out("")
            terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("~/.local/bin 不在 PATH 里，现在还敲不了 signal-light。"))")
            terminal.out("    \(shellPathHint())")
        }

        terminal.out("")
        terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("第一次连灯，macOS 会弹窗要蓝牙权限，点「允许」就行。"))")
        terminal.out("    如果灯不亮，或者蓝牙权限反复失效，可以给它做个固定签名：")
        terminal.out("      codesign --sign \"Signal Light Dev Local\" \(paths.binURL.path)")

        // In a guided menu session the menu itself walks the user through the
        // next steps (pair → start → …) as offers, so this typed-command
        // checklist would just be dangling, disconnected instructions.
        guard !CLIRuntimeContext.isMenuSession else { return }

        terminal.out("")
        terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))接下来（用 signal-light 按需执行）：")
        terminal.out("    \(terminal.dimmed("1.")) signal-light pair             配对你的红绿灯")
        terminal.out("    \(terminal.dimmed("2.")) signal-light service start    启动后台服务")
        terminal.out("    \(terminal.dimmed("•"))  signal-light hooks install  接入 Agent（会让你选 Claude 还是 Codex）")
        terminal.out("    \(terminal.dimmed("•"))  signal-light                不带参数进交互菜单，跟着选就行")
    }

    /// Stages this CLI's own `signal-light-hooks` helper next to the installed
    /// `signal-light` binary. That is the file agent configs are pointed at, and
    /// it is what `signal-light hooks install <agent>` later discovers (the
    /// locator looks right next to the running binary) — so doing it here is
    /// what makes "hand someone both build products in one folder, they run
    /// install" a complete, self-contained setup rather than one that breaks
    /// the moment they leave the build directory.
    ///
    /// A missing helper is a warning, never a failure: the signal light runs
    /// fine without it — only wiring an agent's hooks needs it, and that step
    /// re-reports the problem with actionable guidance if the file is still
    /// absent by then.
    private func installHooksBinary(paths: SignalLightDaemonPaths, terminal: Terminal) {
        let sourceDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        guard let source = HooksBinaryLocator.locate(executableDirectory: sourceDirectory) else {
            terminal.progress("    • 没有找到 signal-light-hooks，已跳过（灯可以正常使用；安装 Agent hooks 前，请把它和 signal-light 放在同一目录）")
            return
        }
        do {
            _ = try ManagedHooksBinary.install(from: source, to: paths.hooksBinaryURL)
            terminal.progress("    • 准备 hooks 组件 → \(displayPath(paths.hooksBinaryURL))")
        } catch {
            terminal.warn("放置 signal-light-hooks 失败：\(error)")
        }
    }

    /// Copies the currently-running executable into the CLI's own stable
    /// directory. `Bundle.main.executableURL` (not `CommandLine.arguments[0]`,
    /// which can be a relative path or a shell alias) is the reliable way to
    /// find a bare CLI's own binary — the LaunchAgent plist (written later by
    /// `service start`) needs a path that stays valid even if the build
    /// directory this invocation ran from is later deleted or moved.
    private func installBinary(paths: SignalLightDaemonPaths, terminal: Terminal) throws {
        guard let currentExecutable = Bundle.main.executableURL else {
            throw CLIError("无法定位自身的可执行文件。", exitCode: .software)
        }

        try FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)

        if currentExecutable.standardizedFileURL != paths.binURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: paths.binURL.path) {
                try FileManager.default.removeItem(at: paths.binURL)
            }
            try FileManager.default.copyItem(at: currentExecutable, to: paths.binURL)
            terminal.progress("    • 复制程序 → \(displayPath(paths.binURL))")
        } else {
            // Re-running install from the installed copy itself: nothing is
            // copied, so claiming a copy would be describing work that didn't
            // happen (only the path is worth confirming).
            terminal.progress("    • 程序已经在位 → \(displayPath(paths.binURL))")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.binURL.path)
    }

    /// Symlinks `~/.local/bin/signal-light` → the real installed binary, so the
    /// short command resolves on `PATH` for anyone who already has that
    /// (XDG-conventional) directory on it — without this CLI ever writing to
    /// a shell rc file. Re-creates the link on every install so a stale link
    /// left over from an older path is never an issue.
    ///
    /// `~/.local/bin` is shared with every other tool, so whatever already
    /// sits at this path is only replaced when it is the link an earlier
    /// install wrote; a directory is never touched (removing it would delete
    /// its whole tree), and anything else is announced instead of silently
    /// overwritten.
    private func linkIntoPath(paths: SignalLightDaemonPaths, terminal: Terminal) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.pathSymlinkDir, withIntermediateDirectories: true)

        if let attributes = try? fileManager.attributesOfItem(atPath: paths.pathSymlinkURL.path) {
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                throw CLIError(
                    "\(displayPath(paths.pathSymlinkURL)) 是个目录，install 不会去动它；把它挪走再装。",
                    exitCode: .noInput
                )
            }
            if !paths.owns(paths.pathSymlinkURL, fileManager: fileManager) {
                terminal.warn("\(displayPath(paths.pathSymlinkURL)) 上原来有个不是本工具的链接/文件，已经替换成指向 signal-light 的链接。")
            }
            try fileManager.removeItem(at: paths.pathSymlinkURL)
        }
        try fileManager.createSymbolicLink(at: paths.pathSymlinkURL, withDestinationURL: paths.binURL)
        terminal.progress("    • 链接命令 → \(displayPath(paths.pathSymlinkURL))")
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

    /// Abbreviates against the same home `SignalLightDaemonPaths` resolves
    /// (which honors `$HOME`) — `homeDirectoryForCurrentUser` ignores it and
    /// would stop matching the very paths being printed.
    private func displayPath(_ url: URL) -> String {
        let home = SignalLightDaemonPaths.current().home.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
