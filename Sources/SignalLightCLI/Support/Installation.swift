import Foundation
import SignalLightKit

/// The machine-side install steps behind `upgrade`: a fresh machine gets its
/// first installation, an existing one gets updated — the steps are the same
/// either way. Every step is idempotent; the caller adds wording and its own
/// preconditions.
enum Installation {
    struct Outcome {
        /// Whether an installation was already in place when the steps
        /// started — the caller words this as "安装完成" or "升级完成".
        let wasInstalled: Bool
    }

    /// Copies the running binary into place, links the command, stages the
    /// hooks helper, reuses the local signing identity when one is already
    /// configured, and restarts the service when it is running.
    ///
    /// It never starts a stopped service, and it never creates a signing
    /// identity — that opens an authorization prompt and belongs to
    /// `signal-light sign` alone.
    ///
    /// The outcome tells the caller whether to word the result as an install
    /// or an upgrade.
    static func apply(paths: SignalLightDaemonPaths, terminal: Terminal) throws -> Outcome {
        let wasInstalled = FileManager.default.fileExists(atPath: paths.binURL.path)

        try installBinary(paths: paths, terminal: terminal)
        try linkIntoPath(paths: paths, terminal: terminal)
        installHooksBinary(paths: paths, terminal: terminal)
        signInstalledBinaries(paths: paths, terminal: terminal)
        restartRunningService(paths: paths, terminal: terminal)
        recordBuildIdentity(paths: paths, terminal: terminal)

        return Outcome(wasInstalled: wasInstalled)
    }

    /// Whether this process is the installed copy itself, as opposed to a
    /// fresh build run out of `.build/release`. `upgrade` from the installed
    /// copy has nothing new to offer, so it refuses.
    static func isRunningInstalledCopy(paths: SignalLightDaemonPaths) -> Bool {
        guard let currentExecutable = Bundle.main.executableURL else { return false }
        // Reached through the PATH link (`~/.local/bin/signal-light`),
        // `executableURL` is the link itself; resolve both sides, or a
        // PATH-invoked `upgrade` sails past this check and replaces the real
        // binary with a link to itself.
        return currentExecutable.resolvingSymlinksInPath().path == paths.binURL.resolvingSymlinksInPath().path
    }

    /// The ad-hoc signature warning `upgrade` ends with.
    /// Without a stable identity every rebuild invalidates the Bluetooth
    /// grant — the flapping a one-time `signal-light sign` fixes.
    static func printSigningWarningIfNeeded(paths: SignalLightDaemonPaths, terminal: Terminal) {
        guard case .unstable = CodeSigning.state(of: paths.binURL) else { return }
        terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("这个构建使用临时签名：重新构建后蓝牙权限可能失效，运行 signal-light sign 配置固定签名。"))")
    }

    // MARK: - Steps

    /// Stages this CLI's own `agent-hooks` helper next to the installed
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
    private static func installHooksBinary(paths: SignalLightDaemonPaths, terminal: Terminal) {
        // The helper sits next to the real binary; resolve the invoked path
        // first so a symlinked invocation still finds it.
        let sourceDirectory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        guard let source = HooksBinaryLocator.locate(executableDirectory: sourceDirectory) else {
            terminal.progress("    • 没有找到 agent-hooks，已跳过（灯可以正常使用；安装 Agent hooks 前，请把它和 signal-light 放在同一目录）")
            return
        }
        do {
            _ = try ManagedHooksBinary.install(from: source, to: paths.hooksBinaryURL)
            terminal.progress("    • 准备 hooks 组件 → \(displayPath(paths.hooksBinaryURL))")
        } catch {
            terminal.warn("放置 agent-hooks 失败：\(error)")
        }
    }

    /// Signs the freshly installed binaries when a local identity is already
    /// configured, so upgrades keep the stable signature the Bluetooth grant
    /// is tied to. Creation stays in `signal-light sign` on purpose: it opens
    /// an authorization prompt, which an install run must never do.
    private static func signInstalledBinaries(paths: SignalLightDaemonPaths, terminal: Terminal) {
        guard SigningIdentity.isAvailable() else { return }
        for binary in [paths.binURL, paths.hooksBinaryURL] where FileManager.default.fileExists(atPath: binary.path) {
            guard case .unstable = CodeSigning.state(of: binary) else { continue }
            do {
                try SigningIdentity.sign(binary)
                terminal.progress("    • 固定签名 → \(displayPath(binary))")
            } catch {
                terminal.warn("签名 \(displayPath(binary)) 失败：\(error)。可运行 signal-light sign 重试。")
            }
        }
    }

    /// A running service keeps the replaced executable in memory, so the new
    /// binary only takes effect after a restart. A service that is not
    /// running is left alone — installing is not starting.
    private static func restartRunningService(paths: SignalLightDaemonPaths, terminal: Terminal) {
        let control = LaunchAgentControl(paths: paths)
        do {
            if try control.restartIfRunning() {
                terminal.progress("    • 后台服务已重启（新版本生效）")
            }
        } catch {
            terminal.warn("后台服务重启失败：\(error)。可运行 signal-light service restart 重试。")
        }
    }

    /// Records which checkout this build came from, so a later `upgrade`
    /// from the installed copy can tell whether the source has moved on.
    /// A build with no discoverable checkout clears the record instead of
    /// leaving a stale one to compare against.
    static func recordBuildIdentity(paths: SignalLightDaemonPaths, terminal: Terminal) {
        let executableDirectory = Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        guard let repoRoot = executableDirectory.flatMap({ SourceStamp.repoRoot(containing: $0) }),
              let stamp = SourceStamp.compute(repoRoot: repoRoot) else {
            BuildRecord.remove(paths: paths)
            return
        }
        do {
            try BuildRecord(sourceRepo: repoRoot.path, sourceStamp: stamp).save(paths: paths)
        } catch {
            terminal.warn("记录构建来源失败：\(error)")
        }
    }

    /// Copies the currently-running executable into the CLI's own stable
    /// directory. `Bundle.main.executableURL` (not `CommandLine.arguments[0]`,
    /// which can be a relative path or a shell alias) is the reliable way to
    /// find a bare CLI's own binary — the LaunchAgent plist (written later by
    /// `service start`) needs a path that stays valid even if the build
    /// directory this invocation ran from is later deleted or moved.
    private static func installBinary(paths: SignalLightDaemonPaths, terminal: Terminal) throws {
        guard let currentExecutable = Bundle.main.executableURL else {
            throw CLIError("无法定位自身的可执行文件。", exitCode: .software)
        }
        // `copyItem` copies a symlink as a symlink; resolve the invoked path
        // so the installed binary is the real executable, not a link into
        // wherever this build happened to live.
        let sourceBinary = currentExecutable.resolvingSymlinksInPath()

        try FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: paths.binURL.path) {
            try FileManager.default.removeItem(at: paths.binURL)
        }
        try FileManager.default.copyItem(at: sourceBinary, to: paths.binURL)
        terminal.progress("    • 复制程序 → \(displayPath(paths.binURL))")
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
    private static func linkIntoPath(paths: SignalLightDaemonPaths, terminal: Terminal) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.pathSymlinkDir, withIntermediateDirectories: true)

        if let attributes = try? fileManager.attributesOfItem(atPath: paths.pathSymlinkURL.path) {
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                throw CLIError(
                    "\(displayPath(paths.pathSymlinkURL)) 是个目录，安装不会去动它；把它挪走再装。",
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

    /// Abbreviates against the same home `SignalLightDaemonPaths` resolves
    /// (which honors `$HOME`) — `homeDirectoryForCurrentUser` ignores it and
    /// would stop matching the very paths being printed.
    private static func displayPath(_ url: URL) -> String {
        PathText.abbreviated(url, relativeTo: SignalLightDaemonPaths.current().home)
    }
}
