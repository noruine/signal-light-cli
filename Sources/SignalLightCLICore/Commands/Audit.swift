import ArgumentParser
import Foundation
import SignalLightKit

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "只读检查：列出各项文件/服务当前是否存在（卸载后确认无残留）。",
        discussion: """
        默认列出所有本工具管辖的文件、目录与 launchd 服务：● 表示存在，○ 表示不存在。
        装机状态下两者都属正常；卸载后用 --expect-clean 确认没有残留——发现任何残留即以非零退出码结束。
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(help: "以 JSON 格式输出。")
    var json: Bool = false

    @Flag(name: .customLong("expect-clean"), help: "发现残留时以非零退出码结束（供自动化验证使用）。")
    var expectClean: Bool = false

    func run() async throws {
        let paths = SignalLightDaemonPaths.current()
        let jobInfo = LaunchAgentControl(paths: paths).jobInfo()
        let report = DaemonCleanup.audit(paths: paths, socketIsInactive: { !SocketProbe.isActive($0) })
        let isClean = report.remaining.isEmpty && !jobInfo.isLoaded

        if json {
            try printJSON(report: report, jobInfo: jobInfo, isClean: isClean)
        } else {
            printHumanReadable(paths: paths, report: report, jobInfo: jobInfo)
        }

        guard expectClean, !isClean else { return }
        throw CLIError("还有残留没清干净（见上面的列表）。", exitCode: .software)
    }

    private func printHumanReadable(paths: SignalLightDaemonPaths, report: DaemonCleanup.Report, jobInfo: LaunchAgentControl.JobInfo) {
        let terminal = globals.makeTerminal()
        let remainingPaths = Set(report.remaining.map(\.path))
        let liveSocketPaths = Set(report.liveSockets.map(\.path))
        let keptForeignPaths = Set(report.keptForeignEntries.map(\.path))

        // One legend line, then dots only: the per-row verdict words were
        // the part that read like something had gone wrong. ● is the status
        // header's own dot, minus its good/bad colors — in an inventory every
        // state is normal.
        terminal.out(terminal.dimmed("● 存在，○ 不存在；装机状态下都属正常，卸载后用 --expect-clean 查残留。"))
        terminal.out("")

        for path in paths.ownedFiles + paths.ownedSockets {
            // A socket with a live listener is not this CLI's residue — some
            // other program is using it, and cleanup correctly left it alone.
            if liveSocketPaths.contains(path.path) {
                terminal.out("● \(PathText.abbreviated(path))（正在被别的程序使用）")
                continue
            }
            // An inventory path somebody else occupies (a directory where one
            // of our files should be, a repointed PATH link): still there, but
            // not ours to remove.
            if keptForeignPaths.contains(path.path) {
                terminal.out("● \(PathText.abbreviated(path))（不是本工具建的）")
                continue
            }
            let exists = remainingPaths.contains(path.path)
            terminal.out("\(dot(exists, terminal: terminal)) \(PathText.abbreviated(path))")
        }

        // Directories read like everything else — on disk or not; whether a
        // survivor is removable junk is an uninstall-time question for
        // `--expect-clean`.
        for dir in paths.pruneDirsIfEmpty {
            let exists = FileManager.default.fileExists(atPath: dir.path)
            terminal.out("\(dot(exists, terminal: terminal)) \(PathText.abbreviated(dir))")
        }

        let jobLabel = "launchd job (\(SignalLightDaemonPaths.launchAgentLabel))"
        terminal.out("\(dot(jobInfo.isLoaded, terminal: terminal)) \(jobLabel)")
    }

    /// ● for present, dim ○ for absent — the status dot without its colors:
    /// in a plain inventory there is no good or bad state to paint.
    private func dot(_ exists: Bool, terminal: Terminal) -> String {
        exists ? "●" : terminal.dimmed("○")
    }

    private func printJSON(report: DaemonCleanup.Report, jobInfo: LaunchAgentControl.JobInfo, isClean: Bool) throws {
        struct Output: Encodable {
            let clean: Bool
            let remaining: [String]
            /// Sockets a live process still holds — deliberately kept, never
            /// counted as residue.
            let liveSockets: [String]
            /// Inventory paths that exist but were not created by this tool
            /// (never deleted, never residue).
            let keptForeign: [String]
            let launchdJobLoaded: Bool
        }

        let output = Output(
            clean: isClean,
            remaining: report.remaining.map(\.path),
            liveSockets: report.liveSockets.map(\.path),
            keptForeign: report.keptForeignEntries.map(\.path),
            launchdJobLoaded: jobInfo.isLoaded
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(data: try encoder.encode(output), encoding: .utf8) ?? "{}")
    }
}
