import Foundation

public struct ClaudeHookInstallationStatus: Equatable, Sendable {
    public var claudeDirectory: URL
    public var settingsURL: URL
    public var manifestURL: URL
    public var hooksBinaryURL: URL?
    public var managedHooksPresent: Bool
    public var hasClaudeIslandHooks: Bool
    public var manifest: ClaudeHookInstallerManifest?

    public init(
        claudeDirectory: URL,
        settingsURL: URL,
        manifestURL: URL,
        hooksBinaryURL: URL?,
        managedHooksPresent: Bool,
        hasClaudeIslandHooks: Bool,
        manifest: ClaudeHookInstallerManifest?
    ) {
        self.claudeDirectory = claudeDirectory
        self.settingsURL = settingsURL
        self.manifestURL = manifestURL
        self.hooksBinaryURL = hooksBinaryURL
        self.managedHooksPresent = managedHooksPresent
        self.hasClaudeIslandHooks = hasClaudeIslandHooks
        self.manifest = manifest
    }
}

/// `@unchecked`: everything stored here is immutable except
/// `FileManager`, which Foundation treats as thread-safe for these
/// operations.
public final class ClaudeHookInstallationManager: @unchecked Sendable {
    public let claudeDirectory: URL
    public let managedHooksBinaryURL: URL
    /// The `--source` value passed to the hooks binary (e.g. "claude", "qoder", "factory", "codebuddy").
    public let hookSource: String
    private let fileManager: FileManager

    public init(
        claudeDirectory: URL = ClaudeConfigDirectory.resolved(),
        managedHooksBinaryURL: URL = ManagedHooksBinary.defaultURL(),
        hookSource: String = "claude",
        fileManager: FileManager = .default
    ) {
        self.claudeDirectory = claudeDirectory
        // Deliberately NOT `standardizedFileURL`: Foundation's standardization
        // is existence-dependent for the `/private/var` → `/var` symlink
        // prefix, so the same path would standardize differently before and
        // after the binary is copied — rewriting the hook command in agent
        // configs on every re-install (and dropping a backup each time). The
        // caller's path is already absolute and normalized, so use it as-is
        // and the command string stays stable across runs.
        self.managedHooksBinaryURL = managedHooksBinaryURL
        self.hookSource = hookSource
        self.fileManager = fileManager
    }

    public func status(hooksBinaryURL: URL? = nil) throws -> ClaudeHookInstallationStatus {
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let manifestURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.fileName)
        let resolvedHooksBinaryURL = resolvedHooksBinaryURL(explicitURL: hooksBinaryURL)

        let settingsData = try readIfPresent(settingsURL)
        let manifest = loadManifest(at: manifestURL)
        let uninstallMutation = try ClaudeHookInstaller.uninstallSettingsJSON(
            existingData: settingsData,
            managedCommand: resolvedManagedCommand(manifest: manifest)
        )

        return ClaudeHookInstallationStatus(
            claudeDirectory: claudeDirectory,
            settingsURL: settingsURL,
            manifestURL: manifestURL,
            hooksBinaryURL: resolvedHooksBinaryURL,
            managedHooksPresent: uninstallMutation.managedHooksPresent,
            hasClaudeIslandHooks: uninstallMutation.hasClaudeIslandHooks,
            manifest: manifest
        )
    }

    @discardableResult
    public func install(hooksBinaryURL: URL) throws -> ClaudeHookInstallationStatus {
        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let manifestURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.fileName)
        let existingSettings = try readIfPresent(settingsURL)
        let installedHooksBinaryURL = try ManagedHooksBinary.install(
            from: hooksBinaryURL,
            to: managedHooksBinaryURL,
            fileManager: fileManager
        )
        // Built from the destination we asked for, not from `install`'s
        // re-standardized return value — see the init comment for why the
        // difference would rewrite configs on every run under a symlinked
        // home prefix such as /private/var.
        let command = ClaudeHookInstaller.hookCommand(for: managedHooksBinaryURL.path, source: hookSource)
        let mutation = try ClaudeHookInstaller.installSettingsJSON(
            existingData: existingSettings,
            hookCommand: command
        )

        if mutation.changed {
            if fileManager.fileExists(atPath: settingsURL.path) {
                try backupFile(at: settingsURL)
            }
            if let contents = mutation.contents {
                try contents.write(to: settingsURL, options: .atomic)
            }
        }

        let manifest = ClaudeHookInstallerManifest(hookCommand: command)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status(hooksBinaryURL: installedHooksBinaryURL)
    }

    @discardableResult
    public func uninstall() throws -> ClaudeHookInstallationStatus {
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let manifestURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.fileName)
        let manifest = loadManifest(at: manifestURL)
        let existingSettings = try readIfPresent(settingsURL)
        let mutation = try ClaudeHookInstaller.uninstallSettingsJSON(
            existingData: existingSettings,
            managedCommand: resolvedManagedCommand(manifest: manifest)
        )

        if mutation.changed {
            if fileManager.fileExists(atPath: settingsURL.path) {
                try backupFile(at: settingsURL)
            }
            if let contents = mutation.contents {
                try contents.write(to: settingsURL, options: .atomic)
            } else if fileManager.fileExists(atPath: settingsURL.path) {
                try fileManager.removeItem(at: settingsURL)
            }
        }

        // This product's own install record always goes with the install it
        // describes.
        try removeFileIfPresent(manifestURL)

        return try status()
    }

    /// The bytes of a file that may legitimately be absent. Missing reports
    /// as nil; present-but-unreadable throws — treating that as "no file"
    /// would let a later write replace content nobody ever looked at.
    private func readIfPresent(_ url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    /// The exact command string this tool writes — matched byte-for-byte to
    /// recognize only its own hooks. Prefers the install record; without
    /// one, the current hooks binary path still names the only command this
    /// tool ever writes, so dead entries are cleaned up instead of stranded.
    private func resolvedManagedCommand(manifest: ClaudeHookInstallerManifest?) -> String {
        manifest?.hookCommand ?? ClaudeHookInstaller.hookCommand(for: managedHooksBinaryURL.path, source: hookSource)
    }

    private func loadManifest(at url: URL) -> ClaudeHookInstallerManifest? {
        // This tool's own record: when it is missing, unreadable or
        // malformed, degrade to "no record" — the fallback match (the exact
        // command for the current binary path) still finds the hooks this
        // install wrote, and a reinstall rewrites the record. Failing an
        // uninstall over our own bookkeeping would strand those hooks.
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeHookInstallerManifest.self, from: data)
    }

    private func resolvedHooksBinaryURL(explicitURL: URL?) -> URL? {
        if let explicitURL {
            return explicitURL
        }

        guard fileManager.isExecutableFile(atPath: managedHooksBinaryURL.path) else {
            return nil
        }

        return managedHooksBinaryURL
    }

    private func backupFile(at url: URL) throws {
        _ = try HookConfigurationBackup.createCopy(from: url, fileManager: fileManager)
    }

    private func removeFileIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }
}
