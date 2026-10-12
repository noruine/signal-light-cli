
/// Exit codes follow the `sysexits.h` convention (see `man sysexits`) rather
/// than an undifferentiated `exit(1)` for every failure, so scripts driving
/// this CLI can distinguish "you forgot a step" from "something is broken."
public enum CLIExitCode: Int32, Sendable {
    case success = 0
    /// Bad usage: wrong flags, or a destructive action refused for lack of `--yes`.
    case usage = 64
    /// Required input/state is missing (e.g. no device paired yet).
    case noInput = 66
    /// A resource this command needs is unavailable right now (socket held
    /// by another process, Bluetooth off/denied).
    case unavailable = 69
    /// Internal error, or a post-uninstall consistency check failed.
    case software = 70
    /// Configuration/signing problem (surfaced with actionable guidance).
    case config = 78
}

/// The one error type every command throws. `SignalLightCli.main` catches it
/// at the top level, prints `message` to stderr, and exits with `exitCode` —
/// commands themselves never call `exit(_:)` directly.
public struct CLIError: Error, CustomStringConvertible {
    public let message: String
    public let exitCode: CLIExitCode

    public init(_ message: String, exitCode: CLIExitCode) {
        self.message = message
        self.exitCode = exitCode
    }

    public var description: String { message }
}
