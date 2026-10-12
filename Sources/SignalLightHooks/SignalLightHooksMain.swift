import Foundation
import SignalLightKit

/// `signal-light-hooks` — the one process an agent's hook invokes.
///
/// It reads the agent's hook JSON from stdin, normalizes it to a `HookEvent`,
/// and hands it to the daemon over the socket. Nothing goes to stdout and
/// nothing is waited on: signal-light only observes, so approvals and
/// questions stay in the agent's own terminal.
@main
enum SignalLightHooksMain {
    static func main() {
        guard !HookSkipConfiguration.shouldSkipHooks(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        guard let input = try? FileHandle.standardInput.readDataToEndOfFile(), !input.isEmpty else {
            return
        }
        guard let event = event(from: input) else { return }
        HookSocketClient.send(event, to: SignalLightDaemonPaths.current().bridgeSocketURL)
    }

    /// The agent is named by the installed hook command (`--source claude`),
    /// never guessed from the payload — the two payload shapes overlap too
    /// much to tell apart reliably.
    private static func event(from input: Data) -> HookEvent? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--source"), arguments.indices.contains(index + 1) else {
            return nil
        }

        let decoder = JSONDecoder()
        switch arguments[index + 1] {
        case "claude":
            guard let payload = try? decoder.decode(ClaudeHookPayload.self, from: input) else { return nil }
            return HookEventMapper.event(from: payload)
        case "codex":
            guard let payload = try? decoder.decode(CodexHookPayload.self, from: input) else { return nil }
            return HookEventMapper.event(from: payload)
        default:
            return nil
        }
    }
}
