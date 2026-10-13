import Darwin
import Foundation

/// Interactive yes/no confirmation for destructive or optional actions.
/// Callers MUST check `Terminal.isInteractive` before calling this — it does
/// not guard against piped stdin itself, since the non-interactive path
/// (require `--yes`) is a distinct, explicit branch in each command.
public enum Confirm {
    /// A single-line 是/否 picker, so confirming reads exactly like every
    /// other selection in this CLI (arrows to land, Enter to confirm, Esc to
    /// cancel) instead of a typed `[y/N]` whose behavior on a stray key is
    /// unclear. Arrows *land on* an answer — ↑/← is 是, ↓/→ is 否 — so a
    /// repeated or held key never flips the answer back; space still toggles.
    /// `question` stays short (callers put context on its own line above):
    /// the picker repaints in place, and a line wider than the terminal
    /// would scroll a row on every repaint. Renders inline (no screen clear)
    /// so preceding output — a calibration result, an uninstall summary —
    /// stays visible to inform the choice. `defaultAnswer` sets which side
    /// starts highlighted; Esc returns it. Falls back to a typed y/n prompt
    /// when stdin isn't a TTY.
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
        while true {
            // Repaint only when the shown answer changes, so a repeated or
            // held key never scrubs the screen.
            if drawn != yes {
                draw(terminal, question: question, yes: yes)
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
                return defaultAnswer
            case .ignore:
                break
            }
        }
    }

    private static func draw(_ terminal: Terminal, question: String, yes: Bool) {
        let yesLabel = optionLabel(terminal, "是", selected: yes)
        let noLabel = optionLabel(terminal, "否", selected: !yes)
        let hint = terminal.dimmed(terminal.keyBar([.move, .enter("确认"), .escape("取消")]))
        writeStderr("\r\u{1B}[K\(question)  \(yesLabel)  \(noLabel)   \(hint)")
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
