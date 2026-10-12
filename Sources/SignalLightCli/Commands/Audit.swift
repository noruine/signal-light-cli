import ArgumentParser
import Foundation
import SignalLightKit

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "只读检查：列出各项文件/服务当前是否存在（排查安装残留）。",
        discussion: """
        默认列出所有本工具管辖的文件、目录与 launchd 服务，并标注「存在 / 已清除 / 保留」。
        脚本可用 --expect-clean：发现任何残留即以非零退出码结束。
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

        for path in paths.ownedFiles + paths.ownedSockets {
            // A socket with a live listener is not this CLI's residue — it is
            // in use by the App or another bridge, and cleanup correctly left
            // it alone. Same third state as the shared directories below.
            if liveSocketPaths.contains(path.path) {
                terminal.out("\(terminal.dimmed("保留"))  \(path.path)（正在被别的程序使用）")
                continue
            }
            // An inventory path somebody else occupies (a directory where one
            // of our files should be, a repointed PATH link): still there, but
            // not ours to remove — "已清除" would be a claim about a foreign
            // file we never touched.
            if keptForeignPaths.contains(path.path) {
                terminal.out("\(terminal.dimmed("保留"))  \(path.path)（不是本工具建的）")
                continue
            }
            let exists = remainingPaths.contains(path.path)
            terminal.out("\(exists ? terminal.failure("存在") : terminal.success("已清除"))  \(path.path)")
        }

        // Directories have a third state files don't: still on disk but only
        // because other components (the App, hook installers) keep files
        // there — that's not this CLI's residue, and calling it "已清除"
        // would be a lie while calling it "存在" would be a false alarm.
        for dir in paths.pruneDirsIfEmpty {
            let label: String
            if remainingPaths.contains(dir.path) {
                label = terminal.failure("存在")
            } else if FileManager.default.fileExists(atPath: dir.path) {
                label = terminal.dimmed("保留")  // 内含其他组件的文件，非本工具残留
            } else {
                label = terminal.success("已清除")
            }
            terminal.out("\(label)  \(dir.path)")
        }

        let jobLabel = "launchd job (\(SignalLightDaemonPaths.launchAgentLabel))"
        terminal.out("\(jobInfo.isLoaded ? terminal.failure("存在") : terminal.success("已清除"))  \(jobLabel)")
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
