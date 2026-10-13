import CryptoKit
import Foundation

/// A content identity of a source checkout, used by `upgrade` to answer
/// "is there anything new to install?" without git: the manifest, the
/// Makefile and every file under `Sources/` are hashed by content, so
/// uncommitted edits count and replaying an old commit changes the stamp
/// back.
enum SourceStamp {
    /// Walks up from `directory` to the nearest ancestor holding a
    /// `Package.swift` — the checkout a build product was built from.
    static func repoRoot(containing directory: URL, fileManager: FileManager = .default) -> URL? {
        var candidate = directory.standardizedFileURL
        while candidate.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// Full hex SHA-256 over the build-relevant files, or nil when the
    /// tree cannot be read.
    static func compute(repoRoot: URL, fileManager: FileManager = .default) -> String? {
        var files = [
            repoRoot.appendingPathComponent("Package.swift"),
            repoRoot.appendingPathComponent("Makefile"),
        ]
        let sources = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return nil
        }
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(file)
            }
        }
        files.sort { $0.path < $1.path }

        var hasher = SHA256()
        for file in files {
            guard let data = fileManager.contents(atPath: file.path) else { return nil }
            // Path plus a delimiter, so renames and file boundaries can
            // never produce the same byte stream as plain concatenation.
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The part of a stamp that messages show — enough to compare by eye.
    static func abbreviated(_ stamp: String) -> String {
        String(stamp.prefix(12))
    }
}
