import Darwin
import Foundation

/// Single source of truth for every filesystem path `SignalLightCLI` creates.
/// `install`/`uninstall`/`audit` all derive their file lists from this type so
/// cleanup can never drift out of sync with what was actually written.
///
/// Everything lives under `~/.signal-light` (plus the PATH symlink and the
/// LaunchAgent plist): the CLI shares no directory with any other product on
/// the machine, so uninstall can remove exactly this tree.
///
/// `$HOME` is honored so install/uninstall can be exercised end-to-end
/// against an isolated directory instead of the real home. That makes these
/// paths a *test/development* affordance as much as a runtime location:
/// anything launchd starts (the daemon) runs with the real home, and the
/// bridge socket resolves against the real home too (see
/// `bridgeSocketURL` below), so a `$HOME`-overridden environment
/// must not be used to drive `service`/`run` — `SignalLightDaemonRunner`
/// refuses to start in exactly that case.
public struct SignalLightDaemonPaths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static func current(fileManager: FileManager = .default) -> SignalLightDaemonPaths {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return SignalLightDaemonPaths(home: home ?? fileManager.homeDirectoryForCurrentUser)
    }

    /// The real user home, ignoring `$HOME` — what launchd and the agent hook
    /// binaries resolve to. Used to detect the one situation where the CLI's
    /// own paths and the shared bridge socket would disagree.
    public static func systemHome(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    public static var launchAgentLabel: String {
        launchAgentLabel(environment: ProcessInfo.processInfo.environment)
    }

    /// The label lives in the per-user launchd domain, not under `$HOME`: a
    /// sandboxed run with a fake home would otherwise boot out (or register
    /// over) the real user's job. The override mirrors the hooks binary's
    /// `SIGNAL_LIGHT_HOOKS_BINARY`, which exists for the same reason.
    public static func launchAgentLabel(environment: [String: String]) -> String {
        environment["SIGNAL_LIGHT_LAUNCHD_LABEL"] ?? "app.signal-light.daemon"
    }

    public var cliRootDir: URL {
        home.appendingPathComponent(".signal-light", isDirectory: true)
    }

    public var binDir: URL {
        cliRootDir.appendingPathComponent("bin", isDirectory: true)
    }

    /// The installed, user-facing binary is named `signal-light` — the actual
    /// command people type — even though the Swift build product is
    /// `SignalLightCLI` (targets are PascalCase; commands and products
    /// are lowercase: `signal-light`, `agent-hooks`). `install` copies
    /// the build product here under this shorter name.
    public var binURL: URL {
        binDir.appendingPathComponent("signal-light")
    }

    /// A symlink at the XDG-conventional user-binary directory pointing at
    /// `binURL`, so `signal-light` resolves on `PATH` for users who already
    /// have `~/.local/bin` there (increasingly the default — uv/pipx/cargo
    /// all install here) without this CLI ever touching a shell rc file.
    /// `~/.local/bin` itself is a general-purpose directory other tools may
    /// also use, so only this symlink is ever removed on uninstall — the
    /// directory itself is never pruned even if it looks empty.
    public var pathSymlinkDir: URL {
        home.appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    public var pathSymlinkURL: URL {
        pathSymlinkDir.appendingPathComponent("signal-light")
    }

    /// This CLI's own private copy of the `agent-hooks` binary, used by
    /// `hooks install <agent>`. Also the default install target of
    /// `ManagedHooksBinary`, so both live under this CLI's own root.
    public var hooksBinaryURL: URL {
        binDir.appendingPathComponent("agent-hooks")
    }

    public var deviceJSONURL: URL {
        cliRootDir.appendingPathComponent("device.json")
    }

    public var stateJSONURL: URL {
        cliRootDir.appendingPathComponent("state.json")
    }

    public var settingsJSONURL: URL {
        cliRootDir.appendingPathComponent("settings.json")
    }

    /// Where the install records which checkout it was built from, so a
    /// later `upgrade` from the installed copy can tell whether the source
    /// has moved on.
    public var buildJSONURL: URL {
        cliRootDir.appendingPathComponent("build.json")
    }

    public var logURL: URL {
        cliRootDir.appendingPathComponent("signal-light.log")
    }

    public var userDir: URL {
        home.appendingPathComponent(".signal-light", isDirectory: true)
    }

    /// Where `sign` keeps the local self-signed certificate (the private key
    /// only lives in the login keychain). Owned so uninstall removes it like
    /// everything else.
    public var signingDir: URL {
        cliRootDir.appendingPathComponent("signing", isDirectory: true)
    }

    public var signingCertURL: URL {
        signingDir.appendingPathComponent("cert.pem")
    }

    public var launchAgentsDir: URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    public var launchAgentPlistURL: URL {
        launchAgentsDir.appendingPathComponent("\(Self.launchAgentLabel).plist")
    }

    /// The daemon's own runtime socket. Exactly two parties use it, both
    /// from this project: `run` binds it, the `agent-hooks` binary sends to
    /// it.
    ///
    /// `SignalLightDaemonRunner.run` refuses to start when `$HOME` isn't the
    /// real home: a daemon must never bind a socket other than the one its
    /// liveness guard inspected.
    public var bridgeSocketURL: URL {
        cliRootDir.appendingPathComponent("bridge.sock")
    }

    /// Every regular file the CLI is responsible for deleting on uninstall.
    /// Socket files are intentionally excluded here — they require a
    /// liveness check (see `DaemonCleanup`) before it is safe to remove them.
    /// `pathSymlinkURL` MUST be listed (and thus removed) before `binURL`:
    /// `FileManager.fileExists` follows symlinks, so once the real binary is
    /// gone the now-dangling symlink would stop reporting as "exists" and a
    /// naive sequential cleanup would leave it behind forever.
    public var ownedFiles: [URL] {
        [pathSymlinkURL, binURL, hooksBinaryURL, deviceJSONURL, stateJSONURL, settingsJSONURL, buildJSONURL, signingCertURL, logURL, launchAgentPlistURL]
    }

    /// Socket files this CLI writes at runtime, which must only be removed
    /// once confirmed inactive (no other process is listening on them).
    public var ownedSockets: [URL] {
        [bridgeSocketURL]
    }

    /// Directories to `rmdir` (never `rmtree`) after their contents are gone,
    /// innermost first, so a directory that happened to gather other files is
    /// only removed when it is actually empty.
    public var pruneDirsIfEmpty: [URL] {
        // `userDir` and `cliRootDir` are the same directory; listing it twice
        // made audit and uninstall print the same row twice. Dedupe by
        // standardized path, keeping the innermost-first order.
        var seen = Set<String>()
        return [binDir, signingDir, cliRootDir, userDir].filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Whether cleanup may delete the entry at `url`.
    ///
    /// Every entry in this inventory is a file this CLI wrote, in a directory
    /// this CLI created — except the PATH symlink, which sits in the shared
    /// `~/.local/bin`. That one only counts as ours while it is still a
    /// symlink pointing at the installed binary; a directory (or a link
    /// somebody repointed) at one of these paths belongs to whoever put it
    /// there, and deleting it would be exactly the "touched somebody else's
    /// file" failure this inventory exists to prevent. Callers must report
    /// such entries, never remove them.
    public func owns(_ url: URL, fileManager: FileManager = .default) -> Bool {
        // None of these entries is a directory, so one at any of these paths
        // was created by somebody else — and `removeItem` on a directory
        // deletes its whole tree.
        if (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory {
            return false
        }

        if url.standardizedFileURL.path == launchAgentPlistURL.standardizedFileURL.path {
            return ownsLaunchAgentPlist(url, fileManager: fileManager)
        }

        guard url.standardizedFileURL.path == pathSymlinkURL.standardizedFileURL.path else {
            return true
        }

        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let destination = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
        return destination.standardizedFileURL.path == binURL.standardizedFileURL.path
    }

    private func ownsLaunchAgentPlist(_ url: URL, fileManager: FileManager) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              plist["Label"] as? String == Self.launchAgentLabel,
              let arguments = plist["ProgramArguments"] as? [String] else {
            return false
        }
        return arguments == [binURL.path, "run"]
    }
}

/// Pure generator for the LaunchAgent property list. Never touches disk or
/// `launchctl` itself — `LaunchAgentControl` (CLI target) owns that.
public struct LaunchAgentSpec: Sendable {
    public let label: String
    public let programArguments: [String]
    public let stdoutPath: String
    public let stderrPath: String
    /// Whether launchd should start this job at login/`bootstrap` time.
    /// Deliberately a required, explicit parameter (not defaulted to `true`)
    /// — "does it run right now" (`start`/`stop`) and "does it start itself
    /// at every future login" (`autostart enable`/`disable`) are separate
    /// user-facing decisions, and this is the one flag that encodes the
    /// latter, so call sites must always state it on purpose.
    public let runAtLoad: Bool

    public init(label: String, programArguments: [String], stdoutPath: String, stderrPath: String, runAtLoad: Bool) {
        self.label = label
        self.programArguments = programArguments
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.runAtLoad = runAtLoad
    }

    public func makePropertyList() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": runAtLoad,
            // Only a non-zero (crash/kill) exit triggers a restart. A clean
            // `exit(0)` from SIGTERM handling, or a `launchctl bootout`, does
            // not — that split is what lets `stop`/`start` and "crash
            // recovery" coexist without fighting each other.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
        ]
    }

    public func serialize() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: makePropertyList(), format: .xml, options: 0)
    }
}

/// The BLE device the user paired via `signal-light pair`, persisted as
/// plain JSON (not `UserDefaults` — a bare CLI binary writing `UserDefaults`
/// lands in a fragile per-process preference domain and would leave a
/// residue `uninstall` can't reliably find).
public struct SignalLightPairedDevice: Codable, Sendable, Equatable {
    public let name: String
    /// `CBPeripheral.identifier.uuidString` — stable across processes and
    /// launches on the same Mac, so the value `pair` (a foreground process)
    /// saves is directly usable by `run` (a launchd-managed process).
    public let identifier: String

    public init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }
}

public enum SignalLightDeviceStore {
    public static func load(from url: URL, fileManager: FileManager = .default) throws -> SignalLightPairedDevice? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SignalLightPairedDevice.self, from: data)
    }

    public static func save(_ device: SignalLightPairedDevice, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(device).write(to: url, options: .atomic)
    }
}

/// Low-frequency runtime snapshot the daemon writes so a separate `status`
/// invocation can report BLE/bucket state without talking to the daemon
/// process directly. Written only on change, never on a timer.
public struct SignalLightDaemonState: Codable, Sendable, Equatable {
    public enum BLE: String, Codable, Sendable {
        case unauthorized
        case poweredOff
        case disconnected
        case scanning
        case connecting
        case connected
    }

    public var ble: BLE
    public var deviceName: String?
    /// `SignalLightBucket.rawValue` — kept as a plain string here rather than
    /// importing the enum, so this file has zero dependency on `SignalLight.swift`
    /// beyond a string contract, and stays trivially `Codable` either way.
    public var currentBucket: String?
    public var sessions: [SessionRegistry.SessionStatus]?
    public var updatedAt: Date
    /// The writing daemon's process id. The daemon never writes a final
    /// "disconnected" snapshot on shutdown, so readers need a way to tell a
    /// live snapshot from the last one a now-dead process left behind;
    /// `nil` for files written before this field existed.
    public var pid: Int?

    public init(
        ble: BLE,
        deviceName: String?,
        currentBucket: String?,
        sessions: [SessionRegistry.SessionStatus]? = nil,
        updatedAt: Date,
        pid: Int? = nil
    ) {
        self.ble = ble
        self.deviceName = deviceName
        self.currentBucket = currentBucket
        self.sessions = sessions
        self.updatedAt = updatedAt
        self.pid = pid
    }
}

public enum SignalLightDaemonStateStore {
    public static func load(from url: URL, fileManager: FileManager = .default) throws -> SignalLightDaemonState? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SignalLightDaemonState.self, from: data)
    }

    public static func save(_ state: SignalLightDaemonState, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

/// Plans and executes the "leave zero traces" removal of every file this CLI
/// owns. Pure filesystem logic — no CoreBluetooth, no `launchctl`, no
/// process spawning — so it is fully exercisable against a temp directory.
public enum DaemonCleanup {
    public struct Report: Sendable, Equatable {
        public var removedFiles: [URL]
        public var removedDirs: [URL]
        /// Anything that should have been gone but wasn't (or, for `audit`,
        /// simply what currently exists). An empty array after `perform`
        /// means the uninstall was verifiably complete.
        public var remaining: [URL]
        /// Socket files deliberately left in place because a live process is
        /// still listening on them (another bridge or program). They are
        /// somebody else's to own while that process runs, so they must never
        /// make a cleanup look incomplete — see `Uninstall` and `Audit`.
        public var liveSockets: [URL]
        /// Paths in the inventory that exist but are not this CLI's: a
        /// directory where one of our files should be, or a
        /// `~/.local/bin/signal-light` pointing somewhere else. Never deleted,
        /// never counted as residue — but the caller must say they were left
        /// alone, or "不存在" would be a claim about somebody else's file.
        public var keptForeignEntries: [URL]

        public init(
            removedFiles: [URL] = [],
            removedDirs: [URL] = [],
            remaining: [URL] = [],
            liveSockets: [URL] = [],
            keptForeignEntries: [URL] = []
        ) {
            self.removedFiles = removedFiles
            self.removedDirs = removedDirs
            self.remaining = remaining
            self.liveSockets = liveSockets
            self.keptForeignEntries = keptForeignEntries
        }
    }

    /// Deletes every owned file that exists, deletes owned sockets only when
    /// `socketIsInactive` reports true for them (never unlink a socket a
    /// live process still holds — that one is reported under `liveSockets`,
    /// not as residue), then prunes now-empty owned directories
    /// innermost-first. Missing files are skipped and unremovable ones
    /// (permissions, a busy file) never abort the rest — whatever stays on
    /// disk is reported as residue by the audit pass below, so the whole
    /// operation is idempotent by construction and cannot fail wholesale.
    @discardableResult
    public static func perform(
        paths: SignalLightDaemonPaths,
        fileManager: FileManager = .default,
        socketIsInactive: (URL) -> Bool
    ) throws -> Report {
        var report = Report()

        for file in paths.ownedFiles where pathExists(file, fileManager: fileManager) {
            guard paths.owns(file, fileManager: fileManager) else {
                report.keptForeignEntries.append(file)
                continue
            }
            if removeIgnoringFailure(file, fileManager: fileManager) {
                report.removedFiles.append(file)
            }
        }

        for socket in paths.ownedSockets where pathExists(socket, fileManager: fileManager) {
            // Only unlink an actual socket entry. A regular file, directory,
            // or symlink at this reserved path belongs to whoever put it there.
            if !isSocket(socket) {
                report.keptForeignEntries.append(socket)
            } else if socketIsInactive(socket) {
                if removeIgnoringFailure(socket, fileManager: fileManager) {
                    report.removedFiles.append(socket)
                }
            } else {
                report.liveSockets.append(socket)
            }
        }

        for dir in paths.pruneDirsIfEmpty {
            guard fileManager.fileExists(atPath: dir.path) else {
                continue
            }
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
                continue
            }
            // Finder drops `.DS_Store` into any directory the user has ever
            // browsed. It's view metadata, not data — it must never block
            // zero-trace removal of a directory whose real contents are gone.
            guard contents.allSatisfy(isIgnorableDirectoryEntry) else {
                continue
            }
            var allRemoved = true
            for entry in contents {
                if !removeIgnoringFailure(dir.appendingPathComponent(entry), fileManager: fileManager) {
                    allRemoved = false
                }
            }
            if allRemoved, removeIgnoringFailure(dir, fileManager: fileManager) {
                report.removedDirs.append(dir)
            }
        }

        let auditReport = audit(paths: paths, fileManager: fileManager, socketIsInactive: socketIsInactive)
        // A socket this run already probed live is never residue, whatever a
        // second probe says: a wedged listener whose accept backlog reads full
        // can refuse the retry, and `remaining` drives uninstall's hard
        // failure — failing over the one entry cleanup was right to keep.
        report.remaining.append(contentsOf: auditReport.remaining.filter {
            !report.remaining.contains($0) && !report.liveSockets.contains($0)
        })
        report.liveSockets.append(contentsOf: auditReport.liveSockets.filter { !report.liveSockets.contains($0) })
        report.keptForeignEntries.append(contentsOf: auditReport.keptForeignEntries.filter { !report.keptForeignEntries.contains($0) })

        return report
    }

    /// Read-only scan: reports every owned path (files, directories, each
    /// still populated, and sockets no live process holds) that currently
    /// exists, without deleting anything. Sockets with a live listener are
    /// reported separately, so a cleanup that correctly left them alone
    /// reads as "somebody else's, still in use" rather than as failure.
    public static func audit(
        paths: SignalLightDaemonPaths,
        fileManager: FileManager = .default,
        socketIsInactive: (URL) -> Bool
    ) -> Report {
        var report = Report()

        for file in paths.ownedFiles where pathExists(file, fileManager: fileManager) {
            if paths.owns(file, fileManager: fileManager) {
                report.remaining.append(file)
            } else {
                report.keptForeignEntries.append(file)
            }
        }
        for socket in paths.ownedSockets where pathExists(socket, fileManager: fileManager) {
            if !isSocket(socket) {
                report.keptForeignEntries.append(socket)
            } else if socketIsInactive(socket) {
                report.remaining.append(socket)
            } else {
                report.liveSockets.append(socket)
            }
        }
        // A prune directory is only *our* residue if we could have removed it
        // but didn't (empty, or junk-only). One still holding other files — a
        // user's own file dropped under `~/.signal-light`, say — is
        // legitimately theirs to keep, and flagging it would make a perfectly
        // clean uninstall report false residue.
        for dir in paths.pruneDirsIfEmpty where fileManager.fileExists(atPath: dir.path) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            if contents.allSatisfy(isIgnorableDirectoryEntry) {
                report.remaining.append(dir)
            }
        }

        return report
    }

    private static func isIgnorableDirectoryEntry(_ name: String) -> Bool {
        name == ".DS_Store"
    }

    /// `removeItem` that never throws: an entry that refuses to leave
    /// (permissions, an open handle) must not abort the rest of the cleanup.
    /// Whatever stays on disk is picked up as residue by the audit pass, so
    /// the failure still surfaces to the caller — as a report, not a crash.
    private static func removeIgnoringFailure(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.removeItem(at: url)) != nil
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let mode = fileMode(at: url) else { return false }
        return mode & S_IFMT == S_IFDIR
    }

    private static func isSocket(_ url: URL) -> Bool {
        guard let mode = fileMode(at: url) else { return false }
        return mode & S_IFMT == S_IFSOCK
    }

    private static func fileMode(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode
    }

    /// `FileManager.fileExists` follows symlinks, so a dangling one (its
    /// target already deleted) silently reports "doesn't exist" even though
    /// the link file itself is still on disk — exactly the case for
    /// `pathSymlinkURL` if it were ever checked after its target. Checking
    /// attributes instead uses `lstat` semantics: it succeeds for a symlink
    /// regardless of whether the target resolves, so a stray link can never
    /// be silently left behind.
    private static func pathExists(_ url: URL, fileManager: FileManager) -> Bool {
        fileMode(at: url) != nil
    }
}
