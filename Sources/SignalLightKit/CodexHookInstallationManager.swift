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

        let configContents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let hooksData = try? Data(contentsOf: hooksURL)
        let manifest = try loadManifest(at: manifestURL)
        let managedCommand = manifest?.hookCommand ?? resolvedHooksBinaryURL.map { CodexHookInstaller.hookCommand(for: $0.path) }
        let managedHooksPresent = ((try? CodexHookInstaller.uninstallHooksJSON(
            existingData: hooksData,
            managedCommand: managedCommand
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

        let existingConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let existingHooks = try? Data(contentsOf: hooksURL)
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
        let hooksMutation = try CodexHookInstaller.installHooksJSON(existingData: existingHooks, hookCommand: command)

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

        let manifest = try loadManifest(at: manifestURL)
        let existingHooks = try? Data(contentsOf: hooksURL)
        let hooksMutation = try CodexHookInstaller.uninstallHooksJSON(
            existingData: existingHooks,
            managedCommand: manifest?.hookCommand
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
            let existingConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
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

    private func loadManifest(at url: URL) throws -> CodexHookInstallerManifest? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexHookInstallerManifest.self, from: data)
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
