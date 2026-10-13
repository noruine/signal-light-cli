import ArgumentParser
import Foundation
import SignalLightKit

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "停止服务并删除 signal-light 的全部文件（程序、配置、日志）。"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: [.customShort("y"), .long], help: "跳过确认提示（非交互环境下必须传入）。")
    var yes: Bool = false

    @Flag(name: .customLong("remove-hooks"), help: "连 Claude Code / Codex 里的 hooks 一起移除（非交互环境只能靠它指定）。")
    var removeHooks: Bool = false

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        guard try confirmDestructiveAction(terminal: terminal) else {
            CancelNotice.say("没有卸载任何内容。", terminal: terminal)
            return
        }
        let alsoRemoveHooks = confirmHooksRemoval(terminal: terminal)

        terminal.progress("\(terminal.emoji(CLIGlyph.cleanup))正在卸载并清理…")

        // Wait for the daemon to fully exit before deleting its files — a
        // still-shutting-down daemon writes state.json/log on its way out,
        // recreating the directories this command just removed and turning a
        // clean uninstall into a phantom "residue detected" failure.
        let control = LaunchAgentControl(paths: paths)
        let serviceWasLoaded = control.jobInfo().isLoaded
        await control.bootoutAndWait()
        if serviceWasLoaded {
            terminal.progress("    • 停止 launchd 服务")
        }

        if alsoRemoveHooks {
            removeHooksFromAgents(terminal: terminal, paths: paths)
        }

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: { !SocketProbe.isActive($0) })

        // Every line below describes something this run actually did. A second
        // uninstall (or a machine where the tool was never installed) has
        // nothing to report there — printing the removal anyway would be the
        // same "removed what never existed" claim this command refuses to
        // make about hooks.
        let removedPaths = Set(report.removedFiles.map(\.path))
        let removedDirs = Set(report.removedDirs.map(\.path))
        let cliFiles = [
            paths.binURL, paths.hooksBinaryURL, paths.deviceJSONURL,
            paths.stateJSONURL, paths.settingsJSONURL, paths.buildJSONURL, paths.logURL,
        ]
        if removedDirs.contains(PathText.abbreviated(paths.cliRootDir))
            || removedDirs.contains(paths.binDir.path)
            || cliFiles.contains(where: { removedPaths.contains($0.path) }) {
            terminal.progress("    • 移除 \(PathText.abbreviated(paths.cliRootDir))（程序、配置、日志、hooks 二进制副本）")
        }
        if removedPaths.contains(PathText.abbreviated(paths.pathSymlinkURL)) {
            terminal.progress("    • 移除 \(PathText.abbreviated(paths.pathSymlinkURL))（PATH 快捷命令；\(PathText.abbreviated(paths.pathSymlinkDir)) 本身不动）")
        }
        if removedPaths.contains(paths.launchAgentPlistURL.path) {
            terminal.progress("    • 移除 LaunchAgent 配置")
        }
        if paths.ownedSockets.contains(where: { removedPaths.contains($0.path) }) {
            terminal.progress("    • 清理运行时 socket")
        }
        // A socket with a live listener (the macOS App, another bridge) is
        // deliberately left alone — that's somebody else's to own while it
        // runs, and it must not make this uninstall look unfinished.
        for socket in report.liveSockets {
            terminal.progress("    • 保留 socket（别的程序在用）：\(PathText.abbreviated(socket))")
        }
        // Same third state for inventory paths somebody else occupies (a
        // directory where one of our files should be, a repointed PATH link):
        // reported, never deleted, never counted as residue.
        for entry in report.keptForeignEntries {
            terminal.progress("    • 保留 \(PathText.abbreviated(entry))（不是本工具建的，没动）")
        }

        guard report.remaining.isEmpty else {
            let list = report.remaining.map { "  - \($0.path)" }.joined(separator: "\n")
            throw CLIError("卸载后仍检测到以下残留，请手动检查：\n\(list)", exitCode: .software)
        }

        if report.removedFiles.isEmpty, report.removedDirs.isEmpty {
            terminal.out("这台机器上没有安装 signal-light，没有可卸载的内容。")
        } else {
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("卸载完成，没留什么文件。"))")
        }
        // A surviving root dir here means it holds files this CLI never
        // created (so cleanup rightly refused to touch them) — say so
        // instead of letting "彻底卸载" quietly overstate what happened.
        // Entries already reported individually above don't need the summary.
        let keptInsideCliRoot = report.keptForeignEntries.contains { $0.path.hasPrefix(PathText.abbreviated(paths.cliRootDir)) }
        if !keptInsideCliRoot, FileManager.default.fileExists(atPath: PathText.abbreviated(paths.cliRootDir)) {
            terminal.warn("\(PathText.abbreviated(paths.cliRootDir)) 里还有不是本工具建的文件，已保留。")
        }
        if !alsoRemoveHooks, !CLIRuntimeContext.isMenuSession {
            terminal.out("    未处理 Agent 的 hooks；想一起卸载：signal-light uninstall --remove-hooks")
        }
    }

    /// The signal light's own files are always removed (that's the whole
    /// point of `uninstall`). Whether to also clean up the *agent-side* hook
    /// entries (`~/.claude/settings.json`, `~/.codex/config.toml`) is a
    /// separate, independent question — those configs are useful even
    /// without the signal light installed — so it gets its own explicit
    /// answer: an interactive prompt, or `--remove-hooks` for scripts.
    /// Non-interactively without the flag, hooks are never touched: there is
    /// no safe default to guess here, only an explicit one to require.
    private func confirmHooksRemoval(terminal: Terminal) -> Bool {
        if removeHooks { return true }
        guard terminal.isInteractive else { return false }
        return Confirm.promptYesNo(terminal, "Claude Code / Codex 里的 hooks 也一起卸掉？", defaultAnswer: false)
    }

    /// Best-effort: a failure removing one agent's hooks (e.g. permissions)
    /// must not abort the rest of `uninstall`, which the user has already
    /// confirmed as destructive and expects to complete. Each line reports
    /// what actually happened — a never-installed agent says so instead of
    /// claiming a removal.
    private func removeHooksFromAgents(terminal: Terminal, paths: SignalLightDaemonPaths) {
        for agent in HookAgent.allCases {
            do {
                let report = try HooksAgentSupport.uninstall(agent, paths: paths)
                terminal.progress(report.didRemove
                    ? "    • \(agent.displayName)：已移除 hooks 配置"
                    : "    • \(agent.displayName)：没有要移除的 hooks")
            } catch {
                terminal.warn("移除 \(agent.displayName) 的 hooks 配置失败：\(error)")
            }
        }
    }

    /// Returns false when the user backs out; the caller then stops quietly
    /// (a declined uninstall is not an error).
    private func confirmDestructiveAction(terminal: Terminal) throws -> Bool {
        guard !yes else { return true }

        guard terminal.isInteractive else {
            throw CLIError(
                "会停止服务并删除全部文件；非交互环境必须加 --yes。",
                exitCode: .usage
            )
        }

        return Confirm.promptYesNo(terminal, "会停掉服务，删掉 signal-light 的所有文件。继续？")
    }
}
