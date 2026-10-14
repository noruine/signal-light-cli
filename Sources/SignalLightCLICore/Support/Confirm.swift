import Darwin
import Foundation

/// Interactive yes/no confirmation for destructive or optional actions.
/// Callers MUST check `Terminal.isInteractive` before calling this — it does
/// not guard against piped stdin itself, since the non-interactive path
/// (require `--yes`) is a distinct, explicit branch in each command.
public enum Confirm {
    /// A 是/否 picker carrying the same frame as every other screen: the
    /// question with its two answers, a blank line, then the key bar on its
    /// own bottom line. Arrows *land on* an answer — ↑/← is 是, ↓/→ is 否 —
    /// so a repeated or held key never flips the answer back; space still
    /// toggles. `question` stays short (callers put context on its own line
    /// above). Renders in place (no screen clear) so preceding output — a
    /// calibration result, an uninstall summary — stays visible to inform
    /// the choice. `defaultAnswer` sets which side starts highlighted; Esc
    /// (like Ctrl-C/Ctrl-D/q, and as the key bar says) always cancels.
    /// Falls back to a typed y/n prompt when stdin isn't a TTY.
    public static func promptYesNo(_ terminal: Terminal, _ question: String, defaultAnswer: Bool = false) -> Bool {
        guard let original = RawMode.enter() else {
            return typedFallback(terminal, question, defaultAnswer: defaultAnswer)
        }
        defer {
            RawMode.restore(original)
            writeStderr("\u{1B}[?25h")  // show cursor
        }
        writeStderr("\u{1B}[?25l")  // hide cursor during navigation

        var yes = defaultAnswer
        var drawn: Bool?
        var frameHeight = 0
        while true {
            // Repaint only when the shown answer changes, so a repeated or
            // held key never scrubs the screen.
            if drawn != yes {
                if frameHeight > 0 {
                    writeStderr("\u{1B}[\(frameHeight - 1)A")  // back to the question line
                    writeStderr("\u{1B}[J")                    // wipe the old frame
                }
                let lines = frame(terminal, question: question, yes: yes)
                frameHeight = lines.count
                writeStderr("\r\u{1B}[K" + lines.joined(separator: "\n\r\u{1B}[K"))
                drawn = yes
            }
            switch readKey() {
            case let .select(answer):
                yes = answer
            case .toggle:
                yes.toggle()
            case .confirm:
                writeStderr("\n")
                return yes
            case .cancel:
                writeStderr("\n")
                // Esc / Ctrl-C / Ctrl-D / q always back out, whatever the
                // default side was: the key bar promises "Esc 取消", so a
                // default-yes question must not read Esc as yes.
                return false
            case .ignore:
                break
            }
        }
    }

    /// The frame every yes/no question shares: the question with both
    /// answers as the body, the shell's blank, then the key bar — composed
    /// through `ScreenLayout` so it can never drift from any other screen.
    /// No breadcrumb of its own: the question continues the screen that
    /// asked it (the confirm renders inline, without a clear).
    static func frame(_ terminal: Terminal, question: String, yes: Bool) -> [String] {
        let yesLabel = optionLabel(terminal, "是", selected: yes)
        let noLabel = optionLabel(terminal, "否", selected: !yes)
        return ScreenLayout.lines(
            terminal: terminal,
            trail: nil,
            context: [],
            body: ["\(question)  \(yesLabel)  \(noLabel)"],
            bar: terminal.keyBar([.move, .enter("确认"), .escape("取消")])
        )
    }

    private static func optionLabel(_ terminal: Terminal, _ text: String, selected: Bool) -> String {
        guard selected else { return "  \(text)  " }
        // Same visible width as the unselected label, so moving the
        // highlight never shifts the question line around.
        return terminal.useColor ? "\u{1B}[7m ❯\(text)  \u{1B}[0m" : " [\(text)] "
    }

    private enum Key {
        case select(Bool)
        case toggle, confirm, cancel, ignore
    }

    private static func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .cancel }

        switch byte {
        case 0x0A, 0x0D:
            return .confirm
        case 0x03, 0x04, 0x71, 0x51:  // Ctrl-C, Ctrl-D, q, Q
            return .cancel
        case 0x20:  // Space toggles, matching the checkbox picker's muscle memory
            return .toggle
        case 0x6B, 0x68:  // k and h (vim up/left) land on 是
            return .select(true)
        case 0x6A, 0x6C:  // j and l (vim down/right) land on 否
            return .select(false)
        case 0x1B:  // Esc, or an arrow-key sequence
            switch RawMode.classifyEscape() {
            case .lone: return .cancel
            case .up, .left: return .select(true)
            case .down, .right: return .select(false)
            case .otherSequence: return .ignore
            }
        default:
            return .ignore
        }
    }

    private static func typedFallback(_ terminal: Terminal, _ question: String, defaultAnswer: Bool) -> Bool {
        let suffix = terminal.dimmed(defaultAnswer ? "[Y/n]" : "[y/N]")
        FileHandle.standardError.write(Data("\(question) \(suffix) ".utf8))
        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased(),
              !line.isEmpty else {
            return defaultAnswer
        }
        return line == "y" || line == "yes"
    }

    private static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
