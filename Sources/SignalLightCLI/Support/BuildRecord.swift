import Foundation
import SignalLightKit

/// Which checkout an installation was built from, written at install time
/// so a later `upgrade` from the installed copy can compare the current
/// source tree against it.
struct BuildRecord: Codable {
    let sourceRepo: String
    let sourceStamp: String

    static func load(paths: SignalLightDaemonPaths) -> BuildRecord? {
        guard let data = try? Data(contentsOf: paths.buildJSONURL) else { return nil }
        return try? JSONDecoder().decode(BuildRecord.self, from: data)
    }

    func save(paths: SignalLightDaemonPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.buildJSONURL, options: .atomic)
    }

    static func remove(paths: SignalLightDaemonPaths) {
        try? FileManager.default.removeItem(at: paths.buildJSONURL)
    }
}
