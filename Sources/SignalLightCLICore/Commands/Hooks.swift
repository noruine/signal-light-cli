import ArgumentParser
import Foundation
import SignalLightKit

/// The two agents this CLI can wire hooks for. `SignalLightKit` has installers
/// for more agents than the CLI exposes; the CLI exposes only the ones this
/// signal light consumes sessions from.
enum HookAgent: String, CaseIterable, ExpressibleByArgument, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

struct Hooks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "接入 Agent：hooks 装好后，会话状态就能驱动信号灯。",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "接入 Agent；不带参数就进勾选界面。"
        )

        @OptionGroup var globals: GlobalOptions

        @Argument(help: "claude 或 codex；省略就进勾选界面。")
        var agent: HookAgent?

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()

            guard let agent else {
                guard terminal.isInteractive else {
                    throw CLIError(
                        "无法在此选择（非终端环境）。请直接指定：signal-light hooks install claude 或 codex。",
                        exitCode: .usage
                    )
                }
                if !(await HooksAgentSetup.run(paths: paths, terminal: terminal)) {
                    CancelNotice.say("已取消。", terminal: terminal)
                }
                return
            }

            let report = try HooksAgentSupport.install(agent, paths: paths)
            HooksReportPrinter.printInstall(report, agent: agent, terminal: terminal)
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "移除 Agent 的 hooks（只删本工具装的那些）。"
        )

        @OptionGroup var globals: GlobalOptions

        @Argument(help: "claude 或 codex；省略就进勾选界面。")
        var agent: HookAgent?

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()

            guard let agent else {
                guard terminal.isInteractive else {
                    throw CLIError(
                        "无法在此选择（非终端环境）。请直接指定：signal-light hooks uninstall claude 或 codex。",
                        exitCode: .usage
                    )
                }
                if !(await HooksAgentSetup.run(paths: paths, terminal: terminal)) {
                    CancelNotice.say("已取消。", terminal: terminal)
                }
                return
            }

            let report = try HooksAgentSupport.uninstall(agent, paths: paths)
            HooksReportPrinter.printUninstall(report, agent: agent, terminal: terminal)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "看看哪些 Agent 已接入；不带参数就都看。"
        )

        @OptionGroup var globals: GlobalOptions

        @Argument(help: "claude 或 codex；省略就都看。")
        var agent: HookAgent?

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()

            var anyInstalled = false
            for target in agent.map({ [$0] }) ?? HookAgent.allCases {
                let report = try HooksAgentSupport.status(target, paths: paths)
                anyInstalled = anyInstalled || report.managedHooksPresent
                HooksReportPrinter.printStatus(report, agent: target, terminal: terminal)
            }

            if !anyInstalled {
                terminal.progress("想接入：运行 signal-light hooks install，或直接运行 signal-light 从菜单里选。")
            }
        }
    }
}

/// Thin, agent-agnostic wrapper over the two `SignalLightKit` installation
/// managers — shared by the `hooks` subcommands and `HooksAgentSetup` so
/// neither reimplements the other's dispatch-by-agent logic.
enum HooksAgentSupport {
    struct Report {
        let managedHooksPresent: Bool
        /// True when this call actually removed managed hooks — so `uninstall`
        /// on a never-installed agent can say so instead of claiming success.
        let didRemove: Bool
        let configDirectory: URL
        let eventNames: [String]
        let notes: [String]
    }

    /// Finds the separately-built `agent-hooks` executable next to this
    /// process's own binary (SwiftPM builds every executable target into the
    /// same `.build/<config>/` directory, so this works for `swift run`,
    /// `swift build`, and the installed copy alike).
    static func locateHooksBinary() throws -> URL {
        guard let url = HooksBinaryLocator.locate(
            executableDirectory: Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        ) else {
            throw CLIError(
                "没有找到 agent-hooks。请运行 swift build --product agent-hooks，并把它和 signal-light 放在同一个 .build 目录。",
                exitCode: .noInput
            )
        }
        return url
    }

    /// Core's `invalidSettingsJSON` / `invalidHooksJSON` descriptions are
    /// English (Kit errors stay UI-neutral). The CLI is Chinese throughout,
    /// so the two config-format failures a user can actually hit are
    /// re-thrown as CLIErrors in the same voice as every other message.
    private static func translatingConfigErrors<T>(file: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch ClaudeHookInstallerError.invalidSettingsJSON {
            throw CLIError("\(file.path) 读不出来（应该是合法的 JSON 对象），先修好再试。", exitCode: .config)
        } catch CodexHookInstallerError.invalidHooksJSON {
            throw CLIError("\(file.path) 读不出来（应该是合法的 JSON 对象），先修好再试。", exitCode: .config)
        }
    }

    static func install(_ agent: HookAgent, paths: SignalLightDaemonPaths) throws -> Report {
        let source = try locateHooksBinary()
        switch agent {
        case .claude:
            let manager = ClaudeHookInstallationManager(
                claudeDirectory: ClaudeConfigDirectory.resolved(),
                managedHooksBinaryURL: paths.hooksBinaryURL
            )
            let status = try translatingConfigErrors(
                file: manager.claudeDirectory.appendingPathComponent("settings.json")
            ) {
                try manager.install(hooksBinaryURL: source)
            }
            return Report(
                managedHooksPresent: status.managedHooksPresent,
                didRemove: false,
                configDirectory: status.claudeDirectory,
                eventNames: ClaudeHookInstaller.managedEventNames,
                notes: status.hasClaudeIslandHooks
                    ? ["claude-island 的 hooks 也在，两边会一起触发。"]
                    : []
            )
        case .codex:
            let manager = CodexHookInstallationManager(managedHooksBinaryURL: paths.hooksBinaryURL)
            let wasInstalled = (try? manager.status(hooksBinaryURL: paths.hooksBinaryURL))?.managedHooksPresent ?? false
            let status = try translatingConfigErrors(
                file: manager.codexDirectory.appendingPathComponent("hooks.json")
            ) {
                try manager.install(hooksBinaryURL: source)
            }
            var notes: [String] = []
            if status.manifest?.enabledCodexHooksFeature == true {
                notes.append("同时在 config.toml 里开启 Codex 的 hooks 开关。")
            }
            // Non-managed Codex hooks are skipped until trusted once; without
            // this the user sees "已接入" while the light stays dark. Only for
            // a fresh install — repeating the instruction on every re-install
            // is noise the user has already read.
            if !wasInstalled {
                notes.append("还需要在 Codex 里运行 /hooks 并确认信任，它才会生效。")
            }
            return Report(
                managedHooksPresent: status.managedHooksPresent,
                didRemove: false,
                configDirectory: status.codexDirectory,
                eventNames: CodexHookInstaller.managedEventNames,
                notes: notes
            )
        }
    }

    static func uninstall(_ agent: HookAgent, paths: SignalLightDaemonPaths) throws -> Report {
        switch agent {
        case .claude:
            let manager = ClaudeHookInstallationManager(
                claudeDirectory: ClaudeConfigDirectory.resolved(),
                managedHooksBinaryURL: paths.hooksBinaryURL
            )
            let before = try translatingConfigErrors(
                file: manager.claudeDirectory.appendingPathComponent("settings.json")
            ) {
                try manager.status(hooksBinaryURL: paths.hooksBinaryURL)
            }
            let status = try translatingConfigErrors(
                file: manager.claudeDirectory.appendingPathComponent("settings.json")
            ) {
                try manager.uninstall()
            }
            return Report(
                managedHooksPresent: status.managedHooksPresent,
                didRemove: before.managedHooksPresent,
                configDirectory: status.claudeDirectory,
                eventNames: [],
                notes: status.hasClaudeIslandHooks ? ["claude-island 的 hooks 没动。"] : []
            )
        case .codex:
            let manager = CodexHookInstallationManager(managedHooksBinaryURL: paths.hooksBinaryURL)
            let before = try translatingConfigErrors(
                file: manager.codexDirectory.appendingPathComponent("hooks.json")
            ) {
                try manager.status(hooksBinaryURL: paths.hooksBinaryURL)
            }
            let status = try translatingConfigErrors(
                file: manager.codexDirectory.appendingPathComponent("hooks.json")
            ) {
                try manager.uninstall()
            }
            return Report(
                managedHooksPresent: status.managedHooksPresent,
                didRemove: before.managedHooksPresent,
                configDirectory: status.codexDirectory,
                eventNames: [],
                notes: []
            )
        }
    }

    static func status(_ agent: HookAgent, paths: SignalLightDaemonPaths) throws -> Report {
        switch agent {
        case .claude:
            let manager = ClaudeHookInstallationManager(
                claudeDirectory: ClaudeConfigDirectory.resolved(),
                managedHooksBinaryURL: paths.hooksBinaryURL
            )
            let status = try translatingConfigErrors(
                file: manager.claudeDirectory.appendingPathComponent("settings.json")
            ) {
                try manager.status(hooksBinaryURL: paths.hooksBinaryURL)
            }
            return Report(
                managedHooksPresent: status.managedHooksPresent,
                didRemove: false,
                configDirectory: status.claudeDirectory,
                eventNames: ClaudeHookInstaller.managedEventNames,
                notes: status.hasClaudeIslandHooks ? ["也有 claude-island 的 hooks。"] : []
            )
        case .codex:
            let manager = CodexHookInstallationManager(managedHooksBinaryURL: paths.hooksBinaryURL)
            let status = try translatingConfigErrors(
                file: manager.codexDirectory.appendingPathComponent("hooks.json")
            ) {
                try manager.status(hooksBinaryURL: paths.hooksBinaryURL)
            }
            var notes: [String] = []
            if status.managedHooksPresent, !status.featureFlagEnabled {
                notes.append("config.toml 里 hooks 开关是关的，不打开就不会跑。")
            }
            return Report(
                managedHooksPresent: status.managedHooksPresent,
                didRemove: false,
                configDirectory: status.codexDirectory,
                eventNames: CodexHookInstaller.managedEventNames,
                notes: notes
            )
        }
    }
}

/// The one interactive flow behind both `signal-light hooks install` (no
/// argument) and the menu's 「接入 Agent」 item: a checkbox screen pre-checked
/// to the agents whose hooks are already installed; on confirm, reality is
/// reconciled to the chosen set — install the newly checked, remove the newly
/// unchecked, leave the rest alone.
enum HooksAgentSetup {
    /// Returns false when the user cancelled without changing anything; the
    /// caller decides what a cancel looks like (a line for a one-shot command,
    /// nothing at all under the menu's own redraw).
    static func run(paths: SignalLightDaemonPaths, terminal: Terminal) async -> Bool {
        let agents = HookAgent.allCases
        let installed = agents.map { (try? HooksAgentSupport.status($0, paths: paths))?.managedHooksPresent ?? false }
        let preselected = Set(installed.enumerated().compactMap { $1 ? $0 : nil })
        let labels = agents.enumerated().map { index, agent in
            "\(agent.displayName)\(installed[index] ? terminal.dimmed("（已接入）") : "")"
        }

        guard let chosen = MultiSelect.choose(
            items: labels,
            preselected: preselected,
            terminal: terminal,
            trail: CLIRuntimeContext.isMenuSession ? ["接入 Agent"] : nil,
            context: {
                ["勾上想让信号灯跟随的 Agent，回车生效。"]
            },
            footerHint: terminal.keyBar([.move, .spaceToggle, .enter("确认"), .escape("返回")])
        ) else {
            // Backing out with Esc is not a result: the menu redraws the
            // previous page, and a one-shot command says "已取消。" itself.
            return false
        }

        var changed = false
        for (index, agent) in agents.enumerated() {
            let want = chosen.contains(index)
            guard want != installed[index] else { continue }
            changed = true
            do {
                if want {
                    let report = try HooksAgentSupport.install(agent, paths: paths)
                    HooksReportPrinter.printInstall(report, agent: agent, terminal: terminal)
                } else {
                    let report = try HooksAgentSupport.uninstall(agent, paths: paths)
                    HooksReportPrinter.printUninstall(report, agent: agent, terminal: terminal)
                }
            } catch let error as CLIError {
                terminal.errorLine("\(agent.displayName)：\(error.message)")
            } catch {
                terminal.errorLine("\(agent.displayName)：\(error)")
            }
        }
        if !changed {
            terminal.out("没有改动。")
        }
        return true
    }
}

/// One place shapes every hooks report, so `hooks install/uninstall/status`
/// and the interactive flow never describe the same state differently.
enum HooksReportPrinter {
    static func printInstall(_ report: HooksAgentSupport.Report, agent: HookAgent, terminal: Terminal) {
        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("\(agent.displayName) 已接入。"))")
        printDetails(report, terminal: terminal)
    }

    static func printUninstall(_ report: HooksAgentSupport.Report, agent: HookAgent, terminal: Terminal) {
        if report.didRemove {
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已移除 \(agent.displayName) 的 hooks。"))")
        } else {
            terminal.out("\(agent.displayName) 里没有本工具安装的 hooks。")
        }
        printDetails(report, terminal: terminal)
    }

    static func printStatus(_ report: HooksAgentSupport.Report, agent: HookAgent, terminal: Terminal) {
        let state = report.managedHooksPresent
            ? terminal.success("已接入")
            : terminal.dimmed("未接入")
        // The colored dot already carries the state; without color it would
        // just duplicate the word next to it ("[off] 未接入").
        let marker = terminal.useColor ? "\(terminal.statusDot(report.managedHooksPresent)) " : ""
        terminal.out("\(marker)\(agent.displayName)  \(state)")
        printDetails(report, terminal: terminal)
    }

    private static func printDetails(_ report: HooksAgentSupport.Report, terminal: Terminal) {
        terminal.out("    配置目录  \(displayPath(report.configDirectory))")
        if report.managedHooksPresent, !report.eventNames.isEmpty {
            terminal.out("    事件      \(report.eventNames.joined(separator: " / "))")
        }
        for note in report.notes {
            terminal.out("    \(terminal.dimmed(note))")
        }
    }

    /// Abbreviates against the home `SignalLightDaemonPaths` resolves (which
    /// honors `$HOME`), so printed paths match the ones scripts use.
    private static func displayPath(_ url: URL) -> String {
        let home = SignalLightDaemonPaths.current().home.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
