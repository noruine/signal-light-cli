import Foundation

public enum ManagedHooksBinary {
    public static let binaryName = "agent-hooks"

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        installDirectory(fileManager: fileManager)
            .appendingPathComponent(binaryName)
            .standardizedFileURL
    }

    public static func candidateURLs(fileManager: FileManager = .default) -> [URL] {
        [defaultURL(fileManager: fileManager)]
    }

    @discardableResult
    public static func install(
        from sourceURL: URL,
        to destinationURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resolvedSourceURL = sourceURL.standardizedFileURL
        let resolvedDestinationURL = (destinationURL ?? defaultURL(fileManager: fileManager)).standardizedFileURL

        try fileManager.createDirectory(
            at: resolvedDestinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if resolvedSourceURL != resolvedDestinationURL {
            if let attributes = try? fileManager.attributesOfItem(atPath: resolvedDestinationURL.path) {
                // Removing a directory would take its whole tree with it — a
                // directory here is not this tool's to delete.
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    throw ManagedHooksBinaryError.destinationIsDirectory(resolvedDestinationURL)
                }
                try fileManager.removeItem(at: resolvedDestinationURL)
            }
            try fileManager.copyItem(at: resolvedSourceURL, to: resolvedDestinationURL)
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedDestinationURL.path)
        return resolvedDestinationURL
    }

    /// Overwrites the installed hooks binary if the source differs. Returns
    /// `true` if the binary was updated.
    @discardableResult
    public static func updateIfNeeded(
        from sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let installedURL = defaultURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: installedURL.path) else {
            return false
        }

        let sourceData = try Data(contentsOf: sourceURL)
        let installedData = try Data(contentsOf: installedURL)
        guard sourceData != installedData else {
            return false
        }

        try fileManager.removeItem(at: installedURL)
        try fileManager.copyItem(at: sourceURL, to: installedURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedURL.path)
        return true
    }

    /// This tool's own bin directory — the same one `install` seeds with its
    /// `agent-hooks` copy, resolved against the real home.
    private static func installDirectory(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".signal-light", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}

/// Why staging the `agent-hooks` helper could not go through.
public enum ManagedHooksBinaryError: Error, LocalizedError, Equatable {
    case destinationIsDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .destinationIsDirectory(let url):
            "\(url.path) is a directory; refusing to replace it with the hooks helper."
        }
    }
}

public enum HooksBinaryLocator {
    public static func locate(
        fileManager: FileManager = .default,
        currentDirectory: URL? = nil,
        executableDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let explicitPath = environment["SIGNAL_LIGHT_HOOKS_BINARY"],
           fileManager.isExecutableFile(atPath: explicitPath) {
            return URL(fileURLWithPath: explicitPath).standardizedFileURL
        }

        let currentDirectory = currentDirectory
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            executableDirectory?.appendingPathComponent("agent-hooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("agent-hooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("Helpers/agent-hooks"),
        ].compactMap { $0 } + ManagedHooksBinary.candidateURLs(fileManager: fileManager) + {
            #if arch(arm64)
            let archTriple = "arm64-apple-macosx"
            #elseif arch(x86_64)
            let archTriple = "x86_64-apple-macosx"
            #endif
            return [
                currentDirectory.appendingPathComponent(".build/\(archTriple)/release/agent-hooks"),
                currentDirectory.appendingPathComponent(".build/release/agent-hooks"),
                currentDirectory.appendingPathComponent(".build/\(archTriple)/debug/agent-hooks"),
                currentDirectory.appendingPathComponent(".build/debug/agent-hooks"),
            ]
        }()

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }

        return nil
    }
}
