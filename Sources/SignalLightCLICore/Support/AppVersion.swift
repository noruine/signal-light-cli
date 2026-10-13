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

    /// What messages show: `v0.1.0 · cbb62b90af76`, or the bare stamp when
    /// the version is unknown.
    static func display(version: String?, stamp: String) -> String {
        let short = SourceStamp.abbreviated(stamp)
        guard let version else { return short }
        return "v\(version) · \(short)"
    }

    /// `<version>+<short stamp>` for `--version`, resolved as close to this
    /// process as possible.
    static func current() -> String {
        if let identity = sourceIdentity() {
            return "\(identity.version ?? "0.0.0")+\(SourceStamp.abbreviated(identity.stamp))"
        }
        if let record = BuildRecord.load(paths: .current()) {
            return "\(record.sourceVersion ?? "0.0.0")+\(SourceStamp.abbreviated(record.sourceStamp))"
        }
        return "0.0.0"
    }

    /// The identity of the checkout this binary lives next to, when it is a
    /// build-tree binary inside one.
    static func sourceIdentity() -> (version: String?, stamp: String)? {
        guard let directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(),
              let repoRoot = SourceStamp.repoRoot(containing: directory),
              let stamp = SourceStamp.compute(repoRoot: repoRoot) else {
            return nil
        }
        return (sourceVersion(repoRoot: repoRoot), stamp)
    }
}
