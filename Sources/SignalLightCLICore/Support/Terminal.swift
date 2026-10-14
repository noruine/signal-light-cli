import Foundation

/// Governs where output goes (stdout for results, stderr for diagnostics —
/// see the CLI's Unix-philosophy requirement) and whether ANSI color /
/// decorative emoji are emitted. Constructed once per invocation from the
/// root command's global options and threaded into subcommands explicitly
/// rather than read from a global singleton, so behavior stays predictable
/// under `--color=always|never` regardless of call site.
public struct Terminal: Sendable {
    public enum ColorMode: String, Sendable, CaseIterable {
        case auto
        case always
        case never
    }

    public let useColor: Bool
    public let useEmoji: Bool
    public let isInteractive: Bool
    public let verbose: Bool
    public let quiet: Bool

    public init(
        colorMode: ColorMode,
        verbose: Bool = false,
        quiet: Bool = false,
        isOutputTTY: Bool = isatty(STDOUT_FILENO) != 0,
        isInputTTY: Bool = isatty(STDIN_FILENO) != 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        switch colorMode {
        case .always:
            useColor = true
        case .never:
            useColor = false
        case .auto:
            // NO_COLOR (https://no-color.org) is a de facto standard: any
            // non-empty value means "don't", regardless of TTY-ness.
            useColor = isOutputTTY && (environment["NO_COLOR"] ?? "").isEmpty
        }
        useEmoji = useColor
        isInteractive = isInputTTY
        self.verbose = verbose
        self.quiet = quiet
    }

    private enum ANSICode: String {
        case red = "31"
        case green = "32"
        case yellow = "33"
        case dim = "2"
    }

    private func colorize(_ text: String, _ code: ANSICode) -> String {
        guard useColor else { return text }
        return "\u{001B}[\(code.rawValue)m\(text)\u{001B}[0m"
    }

    public func success(_ text: String) -> String { colorize(text, .green) }
    public func warning(_ text: String) -> String { colorize(text, .yellow) }
    public func failure(_ text: String) -> String { colorize(text, .red) }
    public func dimmed(_ text: String) -> String { colorize(text, .dim) }

    /// Returns the emoji followed by two spaces when decoration is enabled,
    /// or an empty string when piped/redirected — callers just prepend the
    /// result rather than branching themselves.
    public func emoji(_ symbol: String) -> String {
        useEmoji ? "\(symbol)  " : ""
    }

    /// stdout: the command's result; inside the menu it joins the current page.
    /// Outside the menu, it stays safe to pipe into tools such as `jq`.
    public func out(_ text: String) {
        if MenuActionScreen.append(text) { return }
        print(text)
    }

    /// Progress notes stay on stderr in CLI mode and join the page in the menu.
    public func note(_ text: String) {
        if MenuActionScreen.appendProgress(text) { return }
        writeStderr(text)
    }

    /// Secondary "here's what I'm doing" narration — the bullet lines under a
    /// command's final result. Suppressed under `--quiet`,
    /// unlike the final result line itself (which commands always print via
    /// `out(_:)` regardless of quiet — that line *is* the answer).
    public func progress(_ text: String) {
        guard !quiet else { return }
        if MenuActionScreen.appendProgress(text) { return }
        note(text)
    }

    /// stderr: extra detail only shown under `--verbose`.
    public func debug(_ text: String) {
        guard verbose else { return }
        note(dimmed(text))
    }

    /// stderr: a non-fatal warning.
    public func warn(_ text: String) {
        let message = useColor ? "\(warning("warning:")) \(text)" : "warning: \(text)"
        if MenuActionScreen.appendProgress(message) { return }
        writeStderr(message)
    }

    /// stderr: a fatal error message (the process is expected to exit non-zero after this).
    /// stderr: a failure, prefixed with `error:` — except inside the menu,
    /// which is a guided page rather than a shell and would read the label as
    /// the terminal itself breaking.
    public func errorLine(_ text: String) {
        if MenuActionScreen.append(useColor ? failure(text) : text) { return }
        if CLIRuntimeContext.isMenuSession {
            writeStderr(useColor ? failure(text) : text)
        } else {
            writeStderr(useColor ? "\(failure("error:")) \(text)" : "error: \(text)")
        }
    }

    private func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
