import ArgumentParser
import Foundation
import SignalLightKit

/// Groups every launchd lifecycle operation — starting, stopping,
/// restarting, and toggling login autostart — under one namespace. These
/// four used to be separate top-level commands; folded together here since
/// they're all "control the one background job" and were creating decision
/// paralysis at the top level (which of `start`/`stop`/`restart`/`autostart`
/// do I even want?).
struct Service: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "控制红绿灯后台服务：启动 / 停止 / 重启 / 开机自启。",
        subcommands: [Start.self, Stop.self, Restart.self, Autostart.self]
    )

    /// The preconditions every entry point that hands the job to launchd must
    /// satisfy — `start` and `restart` alike. launchd's `KeepAlive` treats a
    /// daemon that exits non-zero as a crash and restarts it, so starting a
    /// daemon that is guaranteed to fail (not installed yet, or unpaired)
    /// would pin the machine in a ~10-second restart loop.
    static func requireRunnable(paths: SignalLightDaemonPaths) throws {
        // The daemon is launched by launchd from `paths.binURL`, so that
        // stable copy must exist before we can register a service pointing
        // at it — otherwise the plist would reference a path that vanishes
        // with the build directory.
        guard FileManager.default.fileExists(atPath: paths.binURL.path) else {
            throw CLIError(ContextText.choose(cli: "还没装，请在仓库里运行 make install。", menu: "还没装。"), exitCode: .noInput)
        }

        let device: SignalLightPairedDevice?
        do {
            device = try SignalLightDeviceStore.load(from: paths.deviceJSONURL)
        } catch {
            throw CLIError("保存的配对信息读取失败，请重新配对：signal-light pair", exitCode: .config)
        }
        guard device != nil else {
            throw CLIError(ContextText.choose(cli: "还没配对，请运行 signal-light pair。", menu: "还没配对。"), exitCode: .noInput)
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "启动红绿灯后台服务（首次会自动登记 launchd 服务）。"
        )

        @OptionGroup var globals: GlobalOptions

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()
            let control = LaunchAgentControl(paths: paths)

            try Service.requireRunnable(paths: paths)

            let jobInfo = control.jobInfo()
            if jobInfo.pid != nil {
                terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("服务已在运行。"))想重启：signal-light service restart")
                return
            }

            if jobInfo.isLoaded {
                // Registered but its process is gone (killed with SIGTERM
                // outside `service stop`, say): bring the same registration
                // back up rather than telling the user it is already running.
                try control.kickstart()
                terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("服务已启动。"))")
                return
            }

            if control.currentRunAtLoad() == nil {
                // First start: register the launchd service (write the plist
                // and load it). Autostart stays off until explicitly enabled
                // via `service autostart enable` — separate from "run now".
                try control.install(binaryPath: paths.binURL.path, runAtLoad: false)
            } else {
                try control.bootstrap()
            }
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("服务已启动。"))")
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop", abstract: "停止红绿灯后台服务。")

        @OptionGroup var globals: GlobalOptions

        func run() async throws {
            let terminal = globals.makeTerminal()
            let control = LaunchAgentControl(paths: .current())

            guard control.jobInfo().isLoaded else {
                terminal.out("服务未运行。")
                return
            }

            try await control.bootoutAndWait()
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("服务已停止。"))")
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "restart", abstract: "重启红绿灯后台服务。")

        @OptionGroup var globals: GlobalOptions

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()
            let control = LaunchAgentControl(paths: paths)

            // Same guards as `start`: restarting an uninstalled/unpaired setup
            // would just hand launchd a daemon that exits non-zero, and
            // `KeepAlive` would restart it every ~10 seconds.
            try Service.requireRunnable(paths: paths)

            if control.jobInfo().isLoaded {
                try control.kickstart()
            } else {
                try control.bootstrap()
            }
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("服务已重启。"))")
        }
    }

    struct Autostart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "autostart",
            abstract: "开关开机自启（不用先停服务）。",
            subcommands: [Enable.self, Disable.self, Status.self]
        )

        struct Enable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "enable",
                abstract: "开启开机自启（下次登录生效）。"
            )

            @OptionGroup var globals: GlobalOptions

            func run() async throws {
                let terminal = globals.makeTerminal()
                try LaunchAgentControl(paths: .current()).setAutostart(true)
                // Just the new state — the command name already said what
                // changed, and the "下次登录生效" caveat lives in --help.
                terminal.out("\(terminal.emoji(CLIGlyph.success))开机自启：\(terminal.success("已开启"))")
            }
        }

        struct Disable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "disable",
                abstract: "关掉开机自启（不会立即停掉服务）。"
            )

            @OptionGroup var globals: GlobalOptions

            func run() async throws {
                let terminal = globals.makeTerminal()
                try LaunchAgentControl(paths: .current()).setAutostart(false)
                terminal.out("\(terminal.emoji(CLIGlyph.success))开机自启：\(terminal.success("已关闭"))")
            }
        }

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "status", abstract: "看看开机自启开着没。")

            @OptionGroup var globals: GlobalOptions

            func run() async throws {
                let terminal = globals.makeTerminal()
                let paths = SignalLightDaemonPaths.current()
                guard let runAtLoad = LaunchAgentControl(paths: paths).currentRunAtLoad() else {
                    // No plist yet: distinguish "not installed" from "installed
                    // but never started" — autostart can be enabled before the
                    // first `service start`, so the latter isn't an error.
                    if FileManager.default.fileExists(atPath: paths.binURL.path) {
                        terminal.out("开机自启：\(terminal.dimmed("未开启"))（还没登记服务，下次登录才生效）")
                    } else {
                        terminal.out(ContextText.choose(cli: "还没装，请在仓库里运行 make install。", menu: "还没装。"))
                    }
                    return
                }
                terminal.out(runAtLoad ? "开机自启：\(terminal.success("已开启"))" : "开机自启：\(terminal.dimmed("未开启"))")
            }
        }
    }
}
