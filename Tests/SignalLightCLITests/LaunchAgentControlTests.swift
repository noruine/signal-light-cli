import Foundation
import Testing
import SignalLightKit

@testable import SignalLightCLICore

@Suite("LaunchAgent shutdown")
struct LaunchAgentControlTests {
    @Test("Waits for the daemon process to exit after bootout")
    func waitsForProcessExit() async throws {
        let control = LaunchAgentControl(
            paths: SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp")),
            processRunner: LaunchctlStub(pid: 2_000_000_000, bootoutExitCode: 0)
        )

        try await control.bootoutAndWait(timeout: 0.1)
    }

    @Test("A daemon that remains alive makes shutdown fail")
    func timesOutWhileProcessIsAlive() async {
        let control = LaunchAgentControl(
            paths: SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp")),
            processRunner: LaunchctlStub(
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                bootoutExitCode: 0
            )
        )

        do {
            try await control.bootoutAndWait(timeout: 0.01)
            Issue.record("Expected shutdown to time out while the test process stays alive")
        } catch let error as CLIError {
            #expect(error.exitCode == .unavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A failed bootout is reported")
    func reportsBootoutFailure() async {
        let control = LaunchAgentControl(
            paths: SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp")),
            processRunner: LaunchctlStub(pid: 2_000_000_000, bootoutExitCode: 1)
        )

        do {
            try await control.bootoutAndWait(timeout: 0.1)
            Issue.record("Expected launchctl bootout to fail")
        } catch let error as CLIError {
            #expect(error.message.contains("停止后台服务失败"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A bootout timeout restores a job that launchd already unloaded")
    func restoresJobAfterBootoutTimeout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-pause-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SignalLightDaemonPaths(home: root)
        try FileManager.default.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        try Data().write(to: paths.launchAgentPlistURL)

        let runner = PauseLaunchctlStub(pid: Int(ProcessInfo.processInfo.processIdentifier))
        let control = LaunchAgentControl(paths: paths, processRunner: runner)
        var bodyRan = false

        do {
            try await DaemonPause.run(
                terminal: Terminal(colorMode: .never, quiet: true, environment: [:]),
                control: control,
                shutdownTimeout: 0.01
            ) {
                bodyRan = true
            }
            Issue.record("Expected shutdown to time out while this test process stays alive")
        } catch let error as CLIError {
            #expect(error.message.contains("等待后台服务退出超时"))
        }

        #expect(!bodyRan)
        #expect(runner.didBootstrap)
    }
}

private struct LaunchctlStub: ProcessRunning {
    let pid: Int
    let bootoutExitCode: Int32

    func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult {
        if arguments.first == "print" {
            return ProcessResult(exitCode: 0, stdout: "pid = \(pid)\n", stderr: "")
        }
        if arguments.first == "bootout" {
            return ProcessResult(exitCode: bootoutExitCode, stdout: "", stderr: "denied")
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected command")
    }
}

private final class PauseLaunchctlStub: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let pid: Int
    private var bootoutCompleted = false
    private var bootstrapCompleted = false

    init(pid: Int) {
        self.pid = pid
    }

    var didBootstrap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bootstrapCompleted
    }

    func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }

        switch arguments.first {
        case "print" where !bootoutCompleted:
            return ProcessResult(exitCode: 0, stdout: "pid = \(pid)\n", stderr: "")
        case "print":
            return ProcessResult(exitCode: 1, stdout: "", stderr: "not loaded")
        case "bootout":
            bootoutCompleted = true
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        case "bootstrap":
            bootstrapCompleted = true
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected command")
        }
    }
}
