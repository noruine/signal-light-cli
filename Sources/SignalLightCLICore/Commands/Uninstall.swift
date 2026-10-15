import ArgumentParser
import Foundation
import SignalLightKit

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "停止服务并清理 signal-light 的程序、数据和 Agent hooks。"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: [.customShort("y"), .long], help: "跳过确认提示（非交互环境下必须传入）。")
    var yes: Bool = false

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        guard try confirmDestructiveAction(terminal: terminal) else {
            // Answering the question was the statement; nothing to add.
            CLIRuntimeContext.markCommandCancelled(.silentCancel)
            return
        }
        terminal.progress("\(terminal.emoji(CLIGlyph.cleanup))正在卸载并清理…")
        var cleanupHadFailures = false

        // Wait for the daemon to fully exit before deleting its files — a
        // still-shutting-down daemon writes state.json/log on its way out,
        // recreating the directories this command just removed and turning a
        // clean uninstall into a phantom "residue detected" failure.
        let control = LaunchAgentControl(paths: paths)
        let serviceWasLoaded = control.jobInfo().isLoaded
        do {
            try await control.bootoutAndWait()
        } catch {
            cleanupHadFailures = true
            terminal.warn("停止 launchd 服务失败：\(error.localizedDescription)。继续清理其他内容。")
        }
        if serviceWasLoaded {
            terminal.progress("    • 停止 launchd 服务")
        }

        // The fixed-signing identity lives outside the home directory (login
        // keychain), so the file cleanup below can't reach it; take it out
        // first while its certificate file still exists on disk.
        let identityRemoval = SigningIdentity.removeIdentity(
            storeDirectory: paths.signingDir,
            keychain: SigningIdentity.loginKeychain(home: paths.home)
        )
        let identityParts = [
            identityRemoval.identityRemoved ? "证书与私钥" : nil,
            identityRemoval.trustRemoved ? "信任设置" : nil,
        ].compactMap { $0 }
        if !identityParts.isEmpty {
            terminal.progress("    • 移除固定签名身份（登录钥匙串里的\(identityParts.joined(separator: "、"))）")
        }

        let hooksRemoval = removeHooksFromAgents(terminal: terminal, paths: paths)
        cleanupHadFailures = hooksRemoval.didFail || cleanupHadFailures

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
        if removedDirs.contains(paths.cliRootDir.path)
            || removedDirs.contains(paths.binDir.path)
            || cliFiles.contains(where: { removedPaths.contains($0.path) }) {
            terminal.progress("    • 移除 \(PathText.abbreviated(paths.cliRootDir))（程序、配置、日志、签名文件、hooks 二进制副本）")
        }
        if removedPaths.contains(paths.pathSymlinkURL.path) {
            terminal.progress("    • 移除 \(PathText.abbreviated(paths.pathSymlinkURL))（PATH 快捷命令；\(PathText.abbreviated(paths.pathSymlinkDir)) 本身不动）")
        }
        if removedPaths.contains(paths.launchAgentPlistURL.path) {
            terminal.progress("    • 移除 LaunchAgent 配置")
        }
        if paths.ownedSockets.contains(where: { removedPaths.contains($0.path) }) {
            terminal.progress("    • 清理运行时 socket")
        }
        // A socket with a live listener is deliberately left alone. The
        // liveness guard below identifies it as in use instead of unlinking it.
        for socket in report.liveSockets {
            terminal.progress("    • 保留 socket（别的程序在用）：\(PathText.abbreviated(socket))")
        }
        // Same third state for inventory paths somebody else occupies (a
        // directory where one of our files should be, a repointed PATH link):
        // reported, never deleted, never counted as residue.
        for entry in report.keptForeignEntries {
            terminal.progress("    • 保留 \(PathText.abbreviated(entry))（不是本工具建的，没动）")
        }

        if !report.remaining.isEmpty {
            cleanupHadFailures = true
            let list = report.remaining.map { "  - \($0.path)" }.joined(separator: "\n")
            terminal.warn("以下 signal-light 文件未能清理：\n\(list)")
        }
        if cleanupHadFailures {
            terminal.out("卸载流程已完成；部分内容未能清理，请检查上方提示。")
        } else if report.removedFiles.isEmpty, report.removedDirs.isEmpty, !hooksRemoval.didRemove {
            terminal.out("这台机器上没有安装 signal-light，没有可卸载的内容。")
        } else {
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("卸载完成，没留什么文件。"))")
        }
        // A surviving root dir here means it holds files this CLI never
        // created (so cleanup rightly refused to touch them) — say so
        // instead of letting "彻底卸载" quietly overstate what happened.
        // Entries already reported individually above don't need the summary.
        let keptInsideCliRoot = report.keptForeignEntries.contains { $0.path.hasPrefix(paths.cliRootDir.path) }
            || report.liveSockets.contains { $0.path.hasPrefix(paths.cliRootDir.path) }
        if !keptInsideCliRoot, FileManager.default.fileExists(atPath: paths.cliRootDir.path) {
            terminal.warn("\(PathText.abbreviated(paths.cliRootDir)) 里还有不是本工具建的文件，已保留。")
        }
    }

    /// Best-effort: a failure removing one agent's hooks (e.g. permissions)
    /// must not abort the rest of `uninstall`, which the user has already
    /// confirmed as destructive and expects to complete. Each line reports
    /// what actually happened — a never-installed agent says so instead of
    /// claiming a removal.
    private func removeHooksFromAgents(
        terminal: Terminal,
        paths: SignalLightDaemonPaths
    ) -> (didRemove: Bool, didFail: Bool) {
        var didRemove = false
        var didFail = false
        for agent in HookAgent.allCases {
            do {
                let report = try HooksAgentSupport.uninstall(agent, paths: paths)
                didRemove = report.didRemove || didRemove
                terminal.progress(report.didRemove
                    ? "    • \(agent.displayName)：已移除 hooks 配置"
                    : "    • \(agent.displayName)：没有要移除的 hooks")
            } catch {
                didFail = true
                terminal.warn("移除 \(agent.displayName) 的 hooks 配置失败：\(error)")
            }
        }
        return (didRemove, didFail)
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

        terminal.out("会停掉服务，删掉 signal-light 的所有文件。")
        return Confirm.promptYesNo(terminal, "继续？")
    }
}
