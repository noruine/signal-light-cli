import Foundation

/// `~`-abbreviated paths for output meant to be read or copied: an absolute
/// `/Users/<name>/…` path is useless to anyone but its owner.
enum PathText {
    static func abbreviated(_ url: URL) -> String {
        abbreviated(url, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Abbreviates against a caller-supplied home. Code that resolves its
    /// paths from `$HOME` (the CLI's own `SignalLightDaemonPaths`) must pass
    /// that same home, or the "~" prefix silently stops matching the paths it
    /// prints.
    static func abbreviated(_ url: URL, relativeTo home: URL) -> String {
        guard url.path.hasPrefix(home.path) else { return url.path }
        return "~" + url.path.dropFirst(home.path.count)
    }
}
