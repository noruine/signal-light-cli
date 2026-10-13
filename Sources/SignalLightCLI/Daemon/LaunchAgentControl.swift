import Foundation
import SignalLightKit

/// Thin wrapper around `launchctl` for the one LaunchAgent job this CLI
/// manages. Every operation targets the `gui/$UID` domain, so nothing here
/// ever needs `sudo`. The plist *content* comes from `LaunchAgentSpec`
/// (Core, pure/testable) — this type only owns writing it to disk and
/// driving `launchctl`.
public struct LaunchAgentControl {
    private let paths: SignalLightDaemonPaths
    private let processRunner: ProcessRunning
    private let uid: uid_t

    public init(
        paths: SignalLightDaemonPaths,
        processRunner: ProcessRunning = SystemProcessRunner(),
        uid: uid_t = getuid()
    ) {
        self.paths = paths
        self.processRunner = processRunner
        self.uid = uid
    }

    private var domainTarget: String { "gui/\(uid)" }
    private var serviceTarget: String { "gui/\(uid)/\(SignalLightDaemonPaths.launchAgentLabel)" }

    /// Writes the plist and (re)loads the job. Idempotent: safe to call
    /// whether or not a previous install is already loaded.
    public func install(binaryPath: String, runAtLoad: Bool) throws {
        try writePlist(binaryPath: binaryPath, runAtLoad: runAtLoad)

        // Ignore failure: nothing being loaded yet is the common case, and
        // this call exists purely to make the following bootstrap idempotent.
        _ = try? processRunner.run(SystemBinary.launchctl, arguments: ["bootout", serviceTarget])

        try runChecked(["bootstrap", domainTarget, paths.launchAgentPlistURL.path], failureContext: "加载 launchd 服务失败")
    }

    /// Reads the `RunAtLoad` value from the plist already on disk, or `nil`
    /// if nothing is installed yet. Used to (a) let `install` default an
    /// interactive re-prompt to whatever was last chosen, and (b) back
    /// `autostart status`.
    public func currentRunAtLoad() -> Bool? {
        guard let data = try? Data(contentsOf: paths.launchAgentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["RunAtLoad"] as? Bool
    }

    /// Flips whether the service starts itself at every future login,
    /// independent of whether it's running right now — deliberately does
    /// *not* touch the currently-loaded job, since "start at login" and "is
    /// running this instant" are separate questions the user should be able
    /// to answer independently (toggling this has no effect until the next
    /// `bootstrap`, e.g. at the next login).
    ///
    /// Works whether or not the service has ever been started: it reuses the
    /// binary path from an existing plist, or falls back to the installed
    /// binary location, so autostart can be turned on right after `install`
    /// without first having to `service start`.
    public func setAutostart(_ enabled: Bool) throws {
        let binaryPath = installedBinaryPath() ?? paths.binURL.path
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw CLIError(ContextText.choose(cli: "还没装，请运行 signal-light install。", menu: "还没装。"), exitCode: .noInput)
        }
        try writePlist(binaryPath: binaryPath, runAtLoad: enabled)
    }

    private func installedBinaryPath() -> String? {
        guard let data = try? Data(contentsOf: paths.launchAgentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else {
            return nil
        }
        return arguments.first
    }

    private func writePlist(binaryPath: String, runAtLoad: Bool) throws {
        let spec = LaunchAgentSpec(
            label: SignalLightDaemonPaths.launchAgentLabel,
            programArguments: [binaryPath, "run"],
            stdoutPath: paths.logURL.path,
            stderrPath: paths.logURL.path,
            runAtLoad: runAtLoad
        )
        try FileManager.default.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        try spec.serialize().write(to: paths.launchAgentPlistURL, options: .atomic)
    }

    /// Unloads the job. Returns normally whether or not it was loaded —
    /// "make sure it's stopped" is inherently idempotent.
    public func bootout() {
        _ = try? processRunner.run(SystemBinary.launchctl, arguments: ["bootout", serviceTarget])
    }

    /// Boots the job out and then waits until the process has actually
    /// exited. `launchctl bootout` returns as soon as the termination signal
    /// is delivered, while the daemon's graceful shutdown can keep writing
    /// `state.json`/log lines for a moment — and those writes recreate the
    /// very directories `uninstall` is busy deleting, or keep holding the
    /// single BLE connection slot an interactive command is about to need.
    /// Times out rather than hanging forever if the process is wedged.
    public func bootoutAndWait(timeout: TimeInterval = 5) async {
        bootout()
        let deadline = Date().addingTimeInterval(timeout)
        while jobInfo().isLoaded, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public func bootstrap() throws {
        guard FileManager.default.fileExists(atPath: paths.launchAgentPlistURL.path) else {
            throw CLIError(ContextText.choose(cli: "服务还没登记，请运行 signal-light service start。", menu: "服务还没登记。"), exitCode: .noInput)
        }
        try runChecked(["bootstrap", domainTarget, paths.launchAgentPlistURL.path], failureContext: "启动服务失败")
    }

    public func kickstart() throws {
        try runChecked(["kickstart", "-k", serviceTarget], failureContext: "重启服务失败")
    }

    /// Restarts the job only when it is actually running, and reports whether
    /// it did. Used after replacing the installed binary: a running service
    /// keeps the previous executable in memory until it restarts, while a
    /// service that is merely registered (or absent) must not be started by
    /// an install.
    public func restartIfRunning() throws -> Bool {
        guard jobInfo().pid != nil else { return false }
        try kickstart()
        return true
    }

    public struct JobInfo {
        public let isLoaded: Bool
        public let pid: Int?
    }

    public func jobInfo() -> JobInfo {
        guard let result = try? processRunner.run(SystemBinary.launchctl, arguments: ["print", serviceTarget]),
              result.exitCode == 0 else {
            return JobInfo(isLoaded: false, pid: nil)
        }
        return JobInfo(isLoaded: true, pid: parsePID(from: result.stdout))
    }

    private func runChecked(_ arguments: [String], failureContext: String) throws {
        let result = try processRunner.run(SystemBinary.launchctl, arguments: arguments)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("\(failureContext)\(detail.isEmpty ? "" : "：\(detail)")", exitCode: .software)
        }
    }

    private func parsePID(from output: String) -> Int? {
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("pid = "), let pid = Int(line.dropFirst("pid = ".count)) {
                return pid
            }
        }
        return nil
    }
}
