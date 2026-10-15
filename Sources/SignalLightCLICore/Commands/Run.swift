import ArgumentParser
import SignalLightKit

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "内部命令：launchd 用它在前台跑守护进程，不建议手动执行。",
        shouldDisplay: false
    )

    func run() async throws {
        try await SignalLightDaemonRunner.run(paths: .current())
    }
}
