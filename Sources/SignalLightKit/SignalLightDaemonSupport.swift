import Foundation

/// Single source of truth for every filesystem path `SignalLightCLI` creates.
/// `install`/`uninstall`/`audit` all derive their file lists from this type so
/// cleanup can never drift out of sync with what was actually written.
///
/// Deliberately kept out of the App's `Application Support/SignalLight`
/// directory: the CLI is a separate, uninstallable product and must not
/// leave files behind in a directory shared with (or owned by) the app.
///
/// `$HOME` is honored so install/uninstall can be exercised end-to-end
/// against an isolated directory instead of the real home. That makes these
/// paths a *test/development* affordance as much as a runtime location:
/// anything launchd starts (the daemon) runs with the real home, and the
/// shared bridge socket is keyed to the real home too (see
/// `bridgeSocketDir` below), so a `$HOME`-overridden environment
/// must not be used to drive `service`/`run` — `SignalLightDaemonRunner`
/// refuses to start in exactly that case.
public struct SignalLightDaemonPaths: Sendable {
    public let home: URL
    public let uid: uid_t

    public init(home: URL, uid: uid_t) {
        self.home = home
        self.uid = uid
    }

    public static func current(fileManager: FileManager = .default, uid: uid_t = getuid()) -> SignalLightDaemonPaths {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return SignalLightDaemonPaths(home: home ?? fileManager.homeDirectoryForCurrentUser, uid: uid)
    }

    /// The real user home, ignoring `$HOME` — what launchd and the agent hook
    /// binaries resolve to. Used to detect the one situation where the CLI's
    /// own paths and the shared bridge socket would disagree.
    public static func systemHome(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    public static let launchAgentLabel = "app.signal-light.daemon"

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
    /// `hooks install <agent>` — deliberately kept under `binDir` rather than
    /// the App's shared `~/Library/Application Support/SignalLight/bin/`
    /// (`ManagedHooksBinary.defaultURL()`), since a user of this standalone
    /// CLI who never installs the App must not end up with files under a
    /// directory the App considers its own.
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

    public var launchAgentsDir: URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    public var launchAgentPlistURL: URL {
        launchAgentsDir.appendingPathComponent("\(Self.launchAgentLabel).plist")
    }

    /// The daemon binds its socket here at a path it does not accept
    /// overriding, so
    /// this constant must track that implementation rather than being derived
    /// from it, to keep this file free of any Dispatch/Darwin socket coupling.
    ///
    /// `SignalLightDaemonRunner.run` refuses to start when `$HOME` isn't the
    /// real home: a daemon must never bind a socket other than the one its
    /// liveness guard inspected.
    public var bridgeSocketDir: URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SignalLight", isDirectory: true)
    }

    public var bridgeSocketURL: URL {
        bridgeSocketDir.appendingPathComponent("bridge.sock")
    }

    /// The path older installs and the macOS App used (host-global under
    /// `/tmp`, keyed by uid) — probed so two daemons never fight over the
    /// light, and cleaned up on uninstall.
    public var legacySocketURL: URL {
        URL(fileURLWithPath: "/tmp/open-island-\(uid).sock")
    }

    /// Every regular file the CLI is responsible for deleting on uninstall.
    /// Socket files are intentionally excluded here — they require a
    /// liveness check (see `DaemonCleanup`) before it is safe to remove them.
    /// `pathSymlinkURL` MUST be listed (and thus removed) before `binURL`:
    /// `FileManager.fileExists` follows symlinks, so once the real binary is
    /// gone the now-dangling symlink would stop reporting as "exists" and a
    /// naive sequential cleanup would leave it behind forever.
    public var ownedFiles: [URL] {
        [pathSymlinkURL, binURL, hooksBinaryURL, deviceJSONURL, stateJSONURL, settingsJSONURL, buildJSONURL, logURL, launchAgentPlistURL]
    }

    /// Socket files this CLI writes at runtime, which must only be removed
    /// once confirmed inactive (no other process is listening on them).
    public var ownedSockets: [URL] {
        [bridgeSocketURL, legacySocketURL]
    }

    /// Directories to `rmdir` (never `rmtree`) after their contents are gone,
    /// innermost first, so a directory shared with other components (the App,
    /// hook installers) is only removed when it is actually empty.
    public var pruneDirsIfEmpty: [URL] {
        [binDir, cliRootDir, userDir, bridgeSocketDir]
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

        guard url.standardizedFileURL.path == pathSymlinkURL.standardizedFileURL.path else {
            return true
        }

        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let destination = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
        return destination.standardizedFileURL.path == binURL.standardizedFileURL.path
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
    public var updatedAt: Date
    /// The writing daemon's process id. The daemon never writes a final
    /// "disconnected" snapshot on shutdown, so readers need a way to tell a
    /// live snapshot from the last one a now-dead process left behind;
    /// `nil` for files written before this field existed.
    public var pid: Int?

    public init(ble: BLE, deviceName: String?, currentBucket: String?, updatedAt: Date, pid: Int? = nil) {
        self.ble = ble
        self.deviceName = deviceName
        self.currentBucket = currentBucket
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
        /// still listening on them (the macOS App, another bridge). They are
        /// somebody else's to own while that process runs, so they must never
        /// make a cleanup look incomplete — see `Uninstall` and `Audit`.
        public var liveSockets: [URL]
        /// Paths in the inventory that exist but are not this CLI's: a
        /// directory where one of our files should be, or a
        /// `~/.local/bin/signal-light` pointing somewhere else. Never deleted,
        /// never counted as residue — but the caller must say they were left
        /// alone, or "已清除" would be a claim about somebody else's file.
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
    /// innermost-first. Missing files are skipped, not errors — the whole
    /// operation is idempotent by construction.
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
            try fileManager.removeItem(at: file)
            report.removedFiles.append(file)
        }

        for socket in paths.ownedSockets where fileManager.fileExists(atPath: socket.path) {
            if socketIsInactive(socket) {
                try fileManager.removeItem(at: socket)
                report.removedFiles.append(socket)
            } else {
                report.liveSockets.append(socket)
            }
        }

        for dir in paths.pruneDirsIfEmpty {
            guard fileManager.fileExists(atPath: dir.path) else {
                continue
            }
            let contents = try fileManager.contentsOfDirectory(atPath: dir.path)
            // Finder drops `.DS_Store` into any directory the user has ever
            // browsed. It's view metadata, not data — it must never block
            // zero-trace removal of a directory whose real contents are gone.
            guard contents.allSatisfy(isIgnorableDirectoryEntry) else {
                continue
            }
            for entry in contents {
                try fileManager.removeItem(at: dir.appendingPathComponent(entry))
            }
            try fileManager.removeItem(at: dir)
            report.removedDirs.append(dir)
        }

        let auditReport = audit(paths: paths, fileManager: fileManager, socketIsInactive: socketIsInactive)
        report.remaining.append(contentsOf: auditReport.remaining.filter { !report.remaining.contains($0) })
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
        for socket in paths.ownedSockets where fileManager.fileExists(atPath: socket.path) {
            if socketIsInactive(socket) {
                report.remaining.append(socket)
            } else {
                report.liveSockets.append(socket)
            }
        }
        // A prune directory is only *our* residue if we could have removed it
        // but didn't (empty, or junk-only). One still holding other
        // components' files — the App's `Application Support/SignalLight`,
        // another tool under `~/.signal-light` — is legitimately theirs to
        // keep, and flagging it would make a perfectly clean uninstall
        // report false residue.
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

    /// `FileManager.fileExists` follows symlinks, so a dangling one (its
    /// target already deleted) silently reports "doesn't exist" even though
    /// the link file itself is still on disk — exactly the case for
    /// `pathSymlinkURL` if it were ever checked after its target. Checking
    /// attributes instead uses `lstat` semantics: it succeeds for a symlink
    /// regardless of whether the target resolves, so a stray link can never
    /// be silently left behind.
    private static func pathExists(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }
}
