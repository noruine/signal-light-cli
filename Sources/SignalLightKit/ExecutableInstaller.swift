import Darwin
import Foundation

/// Installs executable files by staging beside the destination and replacing
/// it with one same-volume rename.
public enum ExecutableInstaller {
    /// Copies an executable to `destination`, sets its mode, then atomically
    /// replaces any existing file there.
    public static func replace(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let resolvedSource = source.resolvingSymlinksInPath()
        let sourceAttributes = try fileManager.attributesOfItem(atPath: resolvedSource.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw ExecutableInstallerError.sourceIsNotRegularFile(resolvedSource)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stagedFile = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: stagedFile) }

        try fileManager.copyItem(at: resolvedSource, to: stagedFile)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedFile.path)

        guard rename(stagedFile.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public enum ExecutableInstallerError: Error, LocalizedError, Equatable {
    case sourceIsNotRegularFile(URL)

    public var errorDescription: String? {
        switch self {
        case let .sourceIsNotRegularFile(url):
            "The executable source is not a regular file: \(url.path)"
        }
    }
}
