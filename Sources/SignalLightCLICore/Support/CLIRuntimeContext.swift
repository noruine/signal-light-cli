
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

    nonisolated(unsafe) private static var shouldExitMenuAfterAction = false

    static func requestMenuExitAfterAction() {
        guard isMenuSession else { return }
        shouldExitMenuAfterAction = true
    }

    static func consumeMenuExitAfterAction() -> Bool {
        defer { shouldExitMenuAfterAction = false }
        return shouldExitMenuAfterAction
    }

    /// The menu path the current action hangs under, set by `MenuLoop` around
    /// every action: screens a command opens (the pairing scan, its device
    /// picker) continue this trail in their crosshairs instead of inventing a
    /// path of their own. Empty outside the menu.
    nonisolated(unsafe) static var menuTrail: [String] = []

    /// How a finished command ended, for the menu loop's post-action step.
    enum CommandEnding {
        /// Ordinary completion — the loop pauses for a keypress.
        case completed
        /// A yes/no question was answered no: the answer is the statement,
        /// so the loop returns straight to the menu.
        case silentCancel
        /// A cancel said its one line — the loop gives it a beat before the
        /// redraw wipes it.
        case announcedCancel
    }

    /// Set by `CancelNotice.say` (announced) or a declined yes/no (silent);
    /// consumed once per action by the menu loop. Written and read on the
    /// same thread (the menu's command chain is one task), like
    /// `isMenuSession`.
    nonisolated(unsafe) private static var ending: CommandEnding = .completed

    static func markCommandCancelled(_ ending: CommandEnding = .announcedCancel) {
        self.ending = ending
    }

    static func consumeCommandEnding() -> CommandEnding {
        defer { ending = .completed }
        return ending
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
