import Foundation

/// The result of running an external process to completion.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// Abstraction over spawning external processes (`launchctl`, `codesign`, …)
/// so command logic can be exercised without actually invoking system
/// binaries — even though this CLI's current test coverage is limited to
/// the pure Core logic (§16 of the spec), this seam keeps that door open
/// and keeps `Commands/*` free of direct `Process` construction.
public protocol ProcessRunning: Sendable {
    @discardableResult
    func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    @discardableResult
    public func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes concurrently *before* waiting for exit. Reading
        // after `waitUntilExit()` (or reading the two pipes sequentially)
        // deadlocks if the child writes more than a pipe's buffer (~64KB):
        // the child blocks on write while we block on wait/the-other-pipe.
        // Current callers emit little output, but this keeps the seam safe
        // for any future one.
        let outCollector = OutputCollector()
        let errCollector = OutputCollector()
        let group = DispatchGroup()
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global().async(group: group) { outCollector.set(outHandle.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: group) { errCollector.set(errHandle.readDataToEndOfFile()) }
        group.wait()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outCollector.data, encoding: .utf8) ?? "",
            stderr: String(data: errCollector.data, encoding: .utf8) ?? ""
        )
    }

    /// Runs a child with the parent's stdio inherited, so a long interactive
    /// step (the `make install` behind an upgrade) prints as it goes instead
    /// of appearing in one burst after the wait.
    public func runInheritingStdio(_ executableURL: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A lock-guarded box so each pipe can be drained on its own background queue
/// and handed back after `DispatchGroup.wait()` without data races.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ value: Data) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public enum SystemBinary {
    public static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    public static let make = URL(fileURLWithPath: "/usr/bin/make")
}
