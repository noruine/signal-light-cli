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
        let manifestURL = resolvedManifestURL()
        let resolvedHooksBinaryURL = resolvedHooksBinaryURL(explicitURL: hooksBinaryURL)

        let settingsData = try? Data(contentsOf: settingsURL)
        let manifest = try loadManifest(at: manifestURL)
        let managedCommand = manifest?.hookCommand ?? resolvedHooksBinaryURL.map { ClaudeHookInstaller.hookCommand(for: $0.path, source: hookSource) }
        let uninstallMutation = try ClaudeHookInstaller.uninstallSettingsJSON(
            existingData: settingsData,
            managedCommand: managedCommand
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
        let legacyManifestURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.legacyFileName)
        let existingSettings = try? Data(contentsOf: settingsURL)
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
        if fileManager.fileExists(atPath: legacyManifestURL.path) {
            try fileManager.removeItem(at: legacyManifestURL)
        }

        return try status(hooksBinaryURL: installedHooksBinaryURL)
    }

    @discardableResult
    public func uninstall() throws -> ClaudeHookInstallationStatus {
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let manifestURL = resolvedManifestURL()
        let primaryManifestURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.fileName)
        let legacyManifestURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.legacyFileName)
        let manifest = try loadManifest(at: manifestURL)
        let existingSettings = try? Data(contentsOf: settingsURL)
        let mutation = try ClaudeHookInstaller.uninstallSettingsJSON(
            existingData: existingSettings,
            managedCommand: manifest?.hookCommand
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
        // describes. The legacy manifest belonged to the old Vibe Island
        // install instead, so the same rule as the config file applies to it:
        // only a run that actually owns or converged this install has any
        // business deleting another product's file.
        let ownsInstallRecord = fileManager.fileExists(atPath: primaryManifestURL.path)
        try removeFileIfPresent(primaryManifestURL)
        if ownsInstallRecord || mutation.changed {
            try removeFileIfPresent(legacyManifestURL)
        }

        return try status()
    }

    private func loadManifest(at url: URL) throws -> ClaudeHookInstallerManifest? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClaudeHookInstallerManifest.self, from: data)
    }

    private func resolvedManifestURL() -> URL {
        let primaryURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.fileName)
        if fileManager.fileExists(atPath: primaryURL.path) {
            return primaryURL
        }

        let legacyURL = claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.legacyFileName)
        return fileManager.fileExists(atPath: legacyURL.path) ? legacyURL : primaryURL
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
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func removeFileIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }
}
