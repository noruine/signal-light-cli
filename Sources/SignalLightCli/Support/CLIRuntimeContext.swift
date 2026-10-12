
/// Whether the current process is running inside the interactive menu rather
/// than as a one-shot `signal-light <subcommand>` invocation.
///
/// The same command bodies back both paths (the menu is a thin shell over the
/// exact same `parseAsRoot` tree), but a few bits of output only make sense on
/// the CLI: the "等价命令" echo and "下一步：signal-light service start"-style
/// command hints guide someone typing commands, yet read as broken, dangling
/// instructions inside a guided menu that should just *offer* the next step.
/// Commands consult this flag to suppress those CLI-only hints when the menu
/// is driving. Set once at startup before any command runs, then only read —
/// so a plain stored flag is safe without synchronization.
enum CLIRuntimeContext {
    nonisolated(unsafe) static var isMenuSession = false

    /// Set by `CancelNotice.say`, consumed by the menu loop: a command that
    /// ended in a user cancel already said its one line, so the loop skips the
    /// post-action "press Enter to continue" that would otherwise follow it.
    /// Written and read on the same thread (the menu's command chain is one
    /// task), like `isMenuSession`.
    nonisolated(unsafe) private static var cancelledCommand = false

    static func markCommandCancelled() { cancelledCommand = true }

    static func consumeCancelledCommand() -> Bool {
        defer { cancelledCommand = false }
        return cancelledCommand
    }
}

/// The one way this CLI says "the user backed out": a warning-colored line on
/// stdout (never the red `error:` path — a cancel is not a failure) plus the
/// marker above. Commands call this and return normally, so a cancel exits 0.
enum CancelNotice {
    static func say(_ message: String, terminal: Terminal) {
        terminal.out(terminal.warning(message))
        CLIRuntimeContext.markCommandCancelled()
    }
}
