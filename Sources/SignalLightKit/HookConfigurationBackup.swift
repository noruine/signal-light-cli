import Foundation

enum HookConfigurationBackup {
    static func createCopy(
        from source: URL,
        fileManager: FileManager = .default,
        at date: Date = .now
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: source.path) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let destination = source.appendingPathExtension("backup.\(timestamp).\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: destination)
        try removePreviousBackups(for: source, keeping: destination, fileManager: fileManager)
        return destination
    }

    private static func removePreviousBackups(
        for source: URL,
        keeping destination: URL,
        fileManager: FileManager
    ) throws {
        let directory = source.deletingLastPathComponent()
        let prefix = "\(source.lastPathComponent).backup."
        let backupPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z(?:\.[A-Fa-f0-9-]{36})?$"#
        let matcher = try NSRegularExpression(pattern: backupPattern)
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        for candidate in candidates where candidate.lastPathComponent != destination.lastPathComponent {
            guard candidate.lastPathComponent.hasPrefix(prefix) else { continue }
            let suffix = String(candidate.lastPathComponent.dropFirst(prefix.count))
            let range = NSRange(suffix.startIndex..., in: suffix)
            guard matcher.firstMatch(in: suffix, range: range) != nil else { continue }
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            try fileManager.removeItem(at: candidate)
        }
    }
}
