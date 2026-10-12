import Foundation

/// `~`-abbreviated paths for output meant to be read or copied: an absolute
/// `/Users/<name>/…` path is useless to anyone but its owner.
enum PathText {
    static func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard url.path.hasPrefix(home) else { return url.path }
        return "~" + url.path.dropFirst(home.count)
    }
}
