import ArgumentParser
import Darwin
import Foundation

// `Terminal.ColorMode` is `RawRepresentable` with `RawValue == String`, so
// ArgumentParser's default `ExpressibleByArgument` extension for that shape
// applies automatically once we declare conformance here — this is the only
// place in the target that needs to know ArgumentParser exists.
extension Terminal.ColorMode: ExpressibleByArgument {}

/// Options every subcommand shares. Threaded in explicitly via `@OptionGroup`
/// rather than read from a global/singleton, so `--color=never` (say) can
/// never leak between commands or accidentally depend on call order.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "着色/emoji 模式：auto（默认，仅交互终端启用）、always、never。")
    var color: Terminal.ColorMode = .auto

    @Flag(name: .shortAndLong, help: "输出更多细节。")
    var verbose: Bool = false

    @Flag(name: .shortAndLong, help: "只输出错误信息，不输出过程提示。")
    var quiet: Bool = false

    func makeTerminal() -> Terminal {
        Terminal(colorMode: color, verbose: verbose, quiet: quiet)
    }
}

@main
struct SignalLightCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signal-light",
        abstract: "红绿灯后台服务：不用开 macOS App 的原生 CLI。",
        discussion: """
        直接运行不带任何参数的 signal-light 会进入交互菜单，跟着选就行。
        第一次装到本机：在仓库里运行 make install（更新同样用它）。

        常用命令（写脚本或熟练后）：
          signal-light upgrade        检查有没有新代码并升级（配对与配置保留）
          signal-light pair           配对你的红绿灯
          signal-light service start  启动后台服务
          signal-light hooks install  接入 Claude Code / Codex（会让你选）
          signal-light config show    查看灯效配置
          signal-light status         查看当前状态
        """,
        version: AppVersion.current(),
        subcommands: [
            Pair.self,
            Unpair.self,
            Upgrade.self,
            Uninstall.self,
            Sign.self,
            Service.self,
            Hooks.self,
            Config.self,
            Calibrate.self,
            Firmware.self,
            Rename.self,
            Status.self,
            Logs.self,
            Audit.self,
            Doctor.self,
            Run.self,
        ]
    )

    /// Overrides ArgumentParser's default `main()` only to translate our own
    /// `CLIError` into the specific `sysexits.h` exit code it carries —
    /// ArgumentParser's own errors (`--help`, `--version`, usage validation)
    /// still fall through to `exit(withError:)` untouched, so those keep
    /// their normal behavior.
    ///
    /// A bare `signal-light` (no arguments at all, interactive terminal) skips
    /// ArgumentParser and drops straight into the `InteractiveMenu`. That is
    /// the only special case: every other invocation — including `config`,
    /// which resolves to its `defaultSubcommand` (`show`) exactly as
    /// ArgumentParser does — takes the normal command path.
    static func main() async {
        // `Terminal(colorMode:)` is a plain designed initializer, unlike
        // `GlobalOptions()` — constructing a `ParsableArguments` type via its
        // implicit memberwise init does *not* properly initialize
        // ArgumentParser's `@Option`/`@Flag` storage (it's only valid after
        // going through `parseAsRoot`/`parse`), so this path must never touch
        // `GlobalOptions` before an actual parse happens.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            let terminal = Terminal(colorMode: .auto)
            if terminal.isInteractive {
                CLIRuntimeContext.isMenuSession = true
                await InteractiveMenu.run(terminal: terminal)
                return
            }
        }

        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let cliError as CLIError {
            // When stdout is a pipe it's fully buffered, so without a flush a
            // command's report (stdout) would appear *after* this error line
            // (stderr, unbuffered) — e.g. `doctor` printing its verdict before
            // the checks it's based on.
            fflush(stdout)
            FileHandle.standardError.write(Data("error: \(cliError.message)\n".utf8))
            Darwin.exit(cliError.exitCode.rawValue)
        } catch {
            exit(withError: error)
        }
    }
}
