import Foundation

/// What kind of signature a binary carries.
///
/// Ad-hoc and unsigned builds get a fresh cdhash on every rebuild, which
/// quietly invalidates the Bluetooth grant TCC recorded for the previous
/// build. Advice about a signing identity only makes sense for those — a
/// properly signed release never needs it.
enum CodeSigning {
    enum State {
        case stable
        case unstable
        case unavailable
    }

    static func state(of binary: URL, processRunner: ProcessRunning = SystemProcessRunner()) -> State {
        guard FileManager.default.fileExists(atPath: binary.path) else { return .unavailable }
        guard let result = try? processRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", binary.path]
        ) else {
            return .unavailable
        }

        guard result.exitCode == 0 else { return .unstable }
        let output = result.stdout + result.stderr
        return output.localizedCaseInsensitiveContains("adhoc") ? .unstable : .stable
    }
}
