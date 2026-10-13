import ArgumentParser
import Foundation
import SignalLightKit

/// Puts this build onto the machine, or — from the installed copy — checks
/// the recorded checkout for new source and offers to rebuild. The
/// machine-side steps are shared through `Installation.apply` either way.
struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "检查有没有新代码并升级（未装过则直接安装）。",
        discussion: """
        从构建目录运行（make install 走的就是这条）：把手里这份构建装到本机；
        它和已安装的那份一模一样时，直接说「已是最新」。配对、灯效配置与
        launchd 设置一律保留；后台服务在运行的话自动重启以使用新版本。

        从已安装的那份运行：找到安装时记录的源码库，比对有没有新代码——
        没有就说「已是最新」；有就问你要不要升级，确认后构建并装上。

        要更新到新代码：先把仓库更新到你要的版本（有远端就 git pull），
        再运行 make install。
        """
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        if Installation.isRunningInstalledCopy(paths: paths) {
            try runFromInstalledCopy(terminal: terminal, paths: paths)
        } else {
            try runFromBuildTree(terminal: terminal, paths: paths)
        }
    }

    /// The build-tree mode: hand the binary in hand to `Installation.apply`.
    /// A binary byte-identical to the installed copy means there is nothing
    /// to do — that is what makes a repeat `make install` report 「已是最新」
    /// instead of reinstalling the same build.
    private func runFromBuildTree(terminal: Terminal, paths: SignalLightDaemonPaths) throws {
        if isSameAsInstalled(paths: paths) {
            // Byte-identical means the source either has not moved or has
            // moved in ways that do not change codegen; either way the
            // installed binary is what this tree builds to, so the record
            // follows the source.
            let identity = AppVersion.sourceIdentity()
            let suffix = identity.map { "（\(AppVersion.display(version: $0.version, stamp: $0.stamp))）" } ?? ""
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已是最新\(suffix)。"))")
            Installation.recordBuildIdentity(paths: paths, terminal: terminal)
            return
        }

        let isFirstInstall = !FileManager.default.fileExists(atPath: paths.binURL.path)
        let progressText = isFirstInstall ? "安装 signal-light 到本机…" : "升级 signal-light 到当前构建…"
        terminal.progress("\(terminal.emoji(isFirstInstall ? CLIGlyph.package : CLIGlyph.upgrade))\(progressText)")

        let outcome = try Installation.apply(paths: paths, terminal: terminal)

        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success(outcome.wasInstalled ? "升级完成。" : "安装完成。"))")

        if !outcome.wasInstalled {
            printFirstInstallHints(paths: paths, terminal: terminal)
        }
        Installation.printSigningWarningIfNeeded(paths: paths, terminal: terminal)

        // In a guided menu session the menu itself walks the user through the
        // next steps (pair → start → …) as offers, so this typed-command
        // checklist would just be dangling, disconnected instructions.
        if !outcome.wasInstalled, !CLIRuntimeContext.isMenuSession {
            terminal.out("")
            terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))运行 signal-light 打开菜单。")
            terminal.out("    命令行用法：signal-light --help")
        }
    }

    /// The installed-copy mode: compare the recorded source stamp against
    /// the checkout it came from. Equal means nothing new; different offers
    /// a rebuild through `make install` in that checkout.
    private func runFromInstalledCopy(terminal: Terminal, paths: SignalLightDaemonPaths) throws {
        guard let record = BuildRecord.load(paths: paths) else {
            terminal.out("升级要用源码库：这台机器还没有安装记录。到仓库里运行 make install。")
            return
        }
        let recordedRepo = URL(fileURLWithPath: record.sourceRepo)
        guard let repoRoot = SourceStamp.repoRoot(containing: recordedRepo),
              let stamp = SourceStamp.compute(repoRoot: repoRoot) else {
            terminal.out("升级要用源码库：安装时记录的 \(PathText.abbreviated(recordedRepo, relativeTo: paths.home)) 找不到。到仓库里运行 make install。")
            return
        }

        let currentVersion = AppVersion.sourceVersion(repoRoot: repoRoot)
        if stamp == record.sourceStamp {
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已是最新（\(AppVersion.display(version: currentVersion, stamp: stamp))）。"))")
            return
        }

        let change = changeText(from: record, toVersion: currentVersion, toStamp: stamp)
        guard terminal.isInteractive else {
            terminal.out("发现新代码 \(change)。要升级：在仓库里运行 make install。")
            return
        }

        terminal.out("发现新代码 \(change)。")
        guard Confirm.promptYesNo(terminal, "升级？") else {
            CLIRuntimeContext.markCommandCancelled(.silentCancel)
            return
        }

        terminal.progress("\(terminal.emoji(CLIGlyph.upgrade))构建并安装到本机…")
        let exitCode = try SystemProcessRunner().runInheritingStdio(
            SystemBinary.make,
            arguments: ["-C", repoRoot.path, "install"]
        )
        guard exitCode == 0 else {
            throw CLIError("构建或安装失败（make install 退出码 \(exitCode)）。", exitCode: .software)
        }
    }

    /// `v0.1.0 → v0.1.1` when the version moved; otherwise the version with
    /// the two stamps in parentheses, so same-version edits still read as a
    /// change instead of as nothing.
    private func changeText(from record: BuildRecord, toVersion: String?, toStamp: String) -> String {
        let fromStamp = SourceStamp.abbreviated(record.sourceStamp)
        let toStamp = SourceStamp.abbreviated(toStamp)
        if let old = record.sourceVersion, let new = toVersion, old != new {
            return "v\(old) → v\(new)"
        }
        guard let new = toVersion else {
            return "\(fromStamp) → \(toStamp)"
        }
        return "v\(new)（\(fromStamp) → \(toStamp)）"
    }

    /// Whether the running build is byte-identical to the installed copy.
    private func isSameAsInstalled(paths: SignalLightDaemonPaths) -> Bool {
        guard FileManager.default.fileExists(atPath: paths.binURL.path),
              let currentExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return false
        }
        return FileManager.default.contentsEqual(atPath: currentExecutable.path, andPath: paths.binURL.path)
    }

    /// The two hints that only make sense right after a first installation:
    /// the command may not be reachable on PATH yet, and the first Bluetooth
    /// connection will ask for permission.
    private func printFirstInstallHints(paths: SignalLightDaemonPaths, terminal: Terminal) {
        if !pathContainsSymlinkDir(paths) {
            terminal.out("")
            terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("~/.local/bin 不在 PATH 里，现在还运行不了 signal-light。"))")
            terminal.out("    \(shellPathHint())")
        }

        terminal.out("")
        terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("首次连接信号灯时，macOS 会弹窗请求蓝牙权限，点「允许」。"))")
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
