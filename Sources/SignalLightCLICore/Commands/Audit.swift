import ArgumentParser
import Foundation
import SignalLightKit

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "只读检查：列出各项文件/服务当前是否存在。",
        discussion: """
        默认列出所有本工具管辖的文件、目录与 launchd 服务：● 表示存在，○ 表示不存在。
        装机状态下两者都属正常。
        """
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(help: "以 JSON 格式输出。")
    var json: Bool = false

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
    }

    private func printHumanReadable(paths: SignalLightDaemonPaths, report: DaemonCleanup.Report, jobInfo: LaunchAgentControl.JobInfo) {
        let terminal = globals.makeTerminal()
        let remainingPaths = Set(report.remaining.map(\.path))
        let liveSocketPaths = Set(report.liveSockets.map(\.path))
        let keptForeignPaths = Set(report.keptForeignEntries.map(\.path))

        // Inside the menu the breadcrumb already names the screen; only a
        // bare `signal-light audit` needs its title, like `status` does.
        if !CLIRuntimeContext.isMenuSession {
            terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))文件清单")
            terminal.out("")
        }

        // One legend line, then dots only: the per-row verdict words were
        // the part that read like something had gone wrong. ● is the status
        // header's own dot, minus its good/bad colors — in an inventory every
        // state is normal.
        terminal.out(terminal.dimmed("● 存在，○ 不存在；装机状态下都属正常。"))
        terminal.out("")

        // Whether the daemon is up decides how to read a live bridge socket:
        // held by our own service is the normal running state; held while
        // the service is down, it is somebody else's listener.
        let daemonIsRunning = jobInfo.isLoaded && jobInfo.pid != nil

        let directories = paths.pruneDirsIfEmpty
        let directoryPaths = Set(directories.map(\.standardizedFileURL.path))
        let entries = (paths.ownedFiles + paths.ownedSockets + directories)
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }

        for path in entries {
            let pathString = path.standardizedFileURL.path
            let label = Self.inventoryLabel(path, root: paths.cliRootDir, directories: directoryPaths)

            // A socket with a live listener is not this CLI's residue —
            // cleanup correctly leaves it alone.
            if liveSocketPaths.contains(path.path) {
                let holder = daemonIsRunning ? "后台服务在用" : "正在被别的程序使用"
                terminal.out("● \(label)（\(holder)）")
                continue
            }
            // An inventory path somebody else occupies (a directory where one
            // of our files should be, a repointed PATH link): still there, but
            // not ours to remove.
            if keptForeignPaths.contains(path.path) {
                terminal.out("● \(label)（不是本工具建的）")
                continue
            }
            let exists = directoryPaths.contains(pathString)
                ? FileManager.default.fileExists(atPath: path.path)
                : remainingPaths.contains(path.path)
            terminal.out("\(dot(exists, terminal: terminal)) \(label)")
        }

        let jobLabel = "launchd job (\(SignalLightDaemonPaths.launchAgentLabel))"
        terminal.out("\(dot(jobInfo.isLoaded, terminal: terminal)) \(jobLabel)")
    }

    static func inventoryLabel(_ path: URL, root: URL, directories: Set<String>) -> String {
        let pathString = path.standardizedFileURL.path
        let rootString = root.standardizedFileURL.path
        guard pathString == rootString || pathString.hasPrefix(rootString + "/") else {
            return PathText.abbreviated(path)
        }

        let name: String
        if pathString == rootString {
            let abbreviatedRoot = PathText.abbreviated(root)
            name = abbreviatedRoot.hasSuffix("/") ? String(abbreviatedRoot.dropLast()) : abbreviatedRoot
        } else {
            name = path.lastPathComponent
        }
        let depth = directories.filter { pathString.hasPrefix($0 + "/") }.count
        let directorySuffix = directories.contains(pathString) ? "/" : ""
        return "\(String(repeating: "  ", count: depth))\(name)\(directorySuffix)"
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
