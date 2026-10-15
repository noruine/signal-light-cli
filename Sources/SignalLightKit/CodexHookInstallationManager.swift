import Foundation

public struct CodexHookInstallationStatus: Equatable, Sendable {
    public var codexDirectory: URL
    public var configURL: URL
    public var hooksURL: URL
    public var manifestURL: URL
    public var hooksBinaryURL: URL?
    public var featureFlagEnabled: Bool
    public var managedHooksPresent: Bool
    public var manifest: CodexHookInstallerManifest?

    public init(
        codexDirectory: URL,
        configURL: URL,
        hooksURL: URL,
        manifestURL: URL,
        hooksBinaryURL: URL?,
        featureFlagEnabled: Bool,
        managedHooksPresent: Bool,
        manifest: CodexHookInstallerManifest?
    ) {
        self.codexDirectory = codexDirectory
        self.configURL = configURL
        self.hooksURL = hooksURL
        self.manifestURL = manifestURL
        self.hooksBinaryURL = hooksBinaryURL
        self.featureFlagEnabled = featureFlagEnabled
        self.managedHooksPresent = managedHooksPresent
        self.manifest = manifest
    }
}

/// `@unchecked`: everything stored here is immutable except
/// `FileManager`, which Foundation treats as thread-safe for these
/// operations.
public final class CodexHookInstallationManager: @unchecked Sendable {
    public let codexDirectory: URL
    public let managedHooksBinaryURL: URL
    private let fileManager: FileManager
    private let featureKeyProvider: @Sendable () -> CodexHooksFeatureFlagKey

    public init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
        managedHooksBinaryURL: URL = ManagedHooksBinary.defaultURL(),
        fileManager: FileManager = .default,
        featureKeyProvider: @escaping @Sendable () -> CodexHooksFeatureFlagKey = CodexHookInstaller.preferredCodexHooksFeatureKey
    ) {
        self.codexDirectory = codexDirectory
        // Not standardized — see `ClaudeHookInstallationManager.init` for why
        // existence-dependent standardization would churn hook commands.
        self.managedHooksBinaryURL = managedHooksBinaryURL
        self.fileManager = fileManager
        self.featureKeyProvider = featureKeyProvider
    }

    public func status(hooksBinaryURL: URL? = nil) throws -> CodexHookInstallationStatus {
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let manifestURL = codexDirectory.appendingPathComponent(CodexHookInstallerManifest.fileName)
        let resolvedHooksBinaryURL = resolvedHooksBinaryURL(explicitURL: hooksBinaryURL)

        let configContents = try readTextIfPresent(configURL) ?? ""
        let hooksData = try readIfPresent(hooksURL)
        let manifest = loadManifest(at: manifestURL)
        let managedHooksPresent = ((try? CodexHookInstaller.uninstallHooksJSON(
            existingData: hooksData,
            managedCommand: resolvedManagedCommand(manifest: manifest)
        ))?.changed) == true

        return CodexHookInstallationStatus(
            codexDirectory: codexDirectory,
            configURL: configURL,
            hooksURL: hooksURL,
            manifestURL: manifestURL,
            hooksBinaryURL: resolvedHooksBinaryURL,
            featureFlagEnabled: CodexHookInstaller.isCodexHooksFeatureEnabled(in: configContents),
            managedHooksPresent: managedHooksPresent,
            manifest: manifest
        )
    }

    @discardableResult
    public func install(hooksBinaryURL: URL) throws -> CodexHookInstallationStatus {
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let manifestURL = codexDirectory.appendingPathComponent(CodexHookInstallerManifest.fileName)

        let existingConfig = try readTextIfPresent(configURL) ?? ""
        let existingHooks = try readIfPresent(hooksURL)
        let previousManifest = loadManifest(at: manifestURL)
        let installedHooksBinaryURL = try ManagedHooksBinary.install(
            from: hooksBinaryURL,
            to: managedHooksBinaryURL,
            fileManager: fileManager
        )

        // Built from the destination we asked for, not from `install`'s
        // re-standardized return value (see the init comment).
        let command = CodexHookInstaller.hookCommand(for: managedHooksBinaryURL.path)
        let featureMutation = CodexHookInstaller.enableCodexHooksFeature(
            in: existingConfig,
            preferredKey: featureKeyProvider()
        )
        let hooksMutation = try CodexHookInstaller.installHooksJSON(
            existingData: existingHooks,
            hookCommand: command,
            previousHookCommand: previousManifest?.hookCommand
        )

        if featureMutation.changed {
            if fileManager.fileExists(atPath: configURL.path) {
                try backupFile(at: configURL)
            }
            try featureMutation.contents.write(to: configURL, atomically: true, encoding: .utf8)
        }
        if hooksMutation.changed {
            if fileManager.fileExists(atPath: hooksURL.path) {
                try backupFile(at: hooksURL)
            }
            if let hooksData = hooksMutation.contents {
                try hooksData.write(to: hooksURL, options: .atomic)
            }
        }

        let manifest = CodexHookInstallerManifest(
            hookCommand: command,
            enabledCodexHooksFeature: featureMutation.featureEnabledByInstaller
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status(hooksBinaryURL: installedHooksBinaryURL)
    }

    @discardableResult
    public func uninstall() throws -> CodexHookInstallationStatus {
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let manifestURL = codexDirectory.appendingPathComponent(CodexHookInstallerManifest.fileName)

        let manifest = loadManifest(at: manifestURL)
        let existingHooks = try readIfPresent(hooksURL)
        let hooksMutation = try CodexHookInstaller.uninstallHooksJSON(
            existingData: existingHooks,
            managedCommand: resolvedManagedCommand(manifest: manifest)
        )

        if hooksMutation.changed {
            if fileManager.fileExists(atPath: hooksURL.path) {
                try backupFile(at: hooksURL)
            }
            if let hooksData = hooksMutation.contents {
                try hooksData.write(to: hooksURL, options: .atomic)
            } else if fileManager.fileExists(atPath: hooksURL.path) {
                try fileManager.removeItem(at: hooksURL)
            }
        }

        // Only a run that owns this install record (our manifest is present)
        // has any business touching the feature flag: a no-op uninstall must
        // leave the config exactly as it found it.
        if let manifest, manifest.enabledCodexHooksFeature, !hooksMutation.hasRemainingHooks {
            let existingConfig = try readTextIfPresent(configURL) ?? ""
            let featureMutation = CodexHookInstaller.disableCodexHooksFeatureIfManaged(in: existingConfig)

            if featureMutation.changed {
                if fileManager.fileExists(atPath: configURL.path) {
                    try backupFile(at: configURL)
                }
                try featureMutation.contents.write(to: configURL, atomically: true, encoding: .utf8)
            }
        }

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

    private func readTextIfPresent(_ url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The exact command string this tool writes — matched byte-for-byte to
    /// recognize only its own hooks. Prefers the install record; without
    /// one, the current hooks binary path still names the only command this
    /// tool ever writes, so dead entries are cleaned up instead of stranded.
    private func resolvedManagedCommand(manifest: CodexHookInstallerManifest?) -> String {
        manifest?.hookCommand ?? CodexHookInstaller.hookCommand(for: managedHooksBinaryURL.path)
    }

    private func loadManifest(at url: URL) -> CodexHookInstallerManifest? {
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
        return try? decoder.decode(CodexHookInstallerManifest.self, from: data)
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
