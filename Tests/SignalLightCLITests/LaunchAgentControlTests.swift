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
