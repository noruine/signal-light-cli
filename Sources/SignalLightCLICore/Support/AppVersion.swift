import Foundation
import SignalLightKit

/// The human-facing version, resolved from whichever side is at hand: the
/// checkout next to a build-tree binary, or the install record for the
/// installed copy. Display only — "is there anything new" compares source
/// stamps, so uncommitted edits stay visible no matter what the version
/// says.
enum AppVersion {
    /// The checkout's `VERSION` file, or nil when the file is missing (an
    /// older checkout) or empty.
    static func sourceVersion(repoRoot: URL) -> String? {
        let url = repoRoot.appendingPathComponent("VERSION")
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The human-facing semantic version, resolved from this checkout or the
    /// installed build record. Source stamps remain internal to change checks.
    static func current() -> String {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           let repoRoot = SourceStamp.repoRoot(containing: executable.deletingLastPathComponent()),
           let version = sourceVersion(repoRoot: repoRoot) {
            return version
        }
        if let record = BuildRecord.load(paths: .current()) {
            return record.sourceVersion ?? "0.0.0"
        }
        return "0.0.0"
    }
}
