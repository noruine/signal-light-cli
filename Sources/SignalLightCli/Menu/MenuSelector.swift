import Darwin

/// A keyboard-driven single-choice picker: ↑/↓ (or vim j/k) move a highlight,
/// Enter confirms, number keys 1–9 quick-select, q/Ctrl-C back out. It enters
/// raw mode only for the duration of key capture and unconditionally restores
/// the terminal (via `defer`) before returning — so whatever action the
/// caller runs next gets a normal cooked terminal for its own `readLine`
/// prompts. Output post-processing (`OPOST`) is deliberately left on, so plain
/// `print` still emits proper CR+LF line breaks while echo/canonical input are
/// off.
enum MenuSelector {
    enum Outcome: Equatable {
        case selected(Int)
        case quit
    }

    static func choose(
        items: [String],
        terminal: Terminal,
        footerHint: String,
        initialIndex: Int = 0,
        header: () -> Void
    ) -> Outcome {
        guard !items.isEmpty else { return .quit }

        // Only drive the raw-mode picker on a real interactive terminal; if
        // stdin isn't a TTY (reused in a pipe/test), fall back to a plain
        // numbered prompt so the menu still works.
        guard let original = RawMode.enter() else {
            return numberFallback(items: items, terminal: terminal, header: header)
        }
        defer {
            RawMode.restore(original)
            print("\u{1B}[?25h", terminator: "")  // show cursor again
            fflush(stdout)
        }
        print("\u{1B}[?25l", terminator: "")  // hide cursor while navigating
        print("\u{1B}[2J", terminator: "")    // one full clear for a clean first paint

        var selected = min(max(initialIndex, 0), items.count - 1)
        while true {
            render(items: items, selected: selected, terminal: terminal, footerHint: footerHint, header: header)
            switch readKey() {
            case .up:
                selected = (selected - 1 + items.count) % items.count
            case .down:
                selected = (selected + 1) % items.count
            case .enter:
                return .selected(selected)
            case let .number(number):
                // Typing a row's number picks it outright, matching the
                // "1. …" labels and the non-TTY fallback's behavior.
                if (1...items.count).contains(number) {
                    return .selected(number - 1)
                }
            case .quit:
                return .quit
            case .other:
                break  // unhandled key: ignore, redraw
            }
        }
    }

    // MARK: - Rendering

    private static func render(
        items: [String],
        selected: Int,
        terminal: Terminal,
        footerHint: String,
        header: () -> Void
    ) {
        print("\u{1B}[H", terminator: "")  // cursor home; redraw over the previous frame
        header()
        // `\u{1B}[K` (erase to end of line) is appended to every redrawn line:
        // the highlighted row (` ❯ text `, reverse-video, with a trailing
        // space) is wider than the plain row (`   text`), so when the
        // selection moves off a row, its old highlight's right-hand tail would
        // otherwise linger as a stray reverse-video block. Clearing to EOL on
        // each line wipes that residue in place.
        let clearToEOL = "\u{1B}[K"
        for (index, label) in items.enumerated() {
            let text = "\(index + 1). \(label)"
            if index == selected {
                if terminal.useColor {
                    print("\u{1B}[7m ❯ \(text) \u{1B}[0m\(clearToEOL)")
                } else {
                    print(" ❯ \(text)\(clearToEOL)")
                }
            } else {
                print("   \(text)\(clearToEOL)")
            }
        }
        print(clearToEOL)
        print("\(terminal.dimmed(footerHint))\(clearToEOL)")
        print("\u{1B}[0J", terminator: "")  // erase anything left from a taller previous frame
        fflush(stdout)
    }

    // MARK: - Key input

    private enum Key {
        case up, down, enter, quit, number(Int), other
    }

    private static func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .quit }  // EOF

        switch byte {
        case 0x0A, 0x0D:
            return .enter
        case 0x03, 0x04, 0x71, 0x51:  // Ctrl-C, Ctrl-D, q, Q
            return .quit
        case 0x6B:  // k
            return .up
        case 0x6A:  // j
            return .down
        case 0x31...0x39:  // 1–9: the labels these rows are rendered with
            return .number(Int(byte - 0x30))
        case 0x1B:
            switch RawMode.classifyEscape() {
            case .lone: return .quit  // a real Esc backs out, same as q
            case .up: return .up
            case .down: return .down
            case .left, .right, .otherSequence: return .other
            }
        default:
            return .other
        }
    }

    // MARK: - Non-TTY fallback

    private static func numberFallback(items: [String], terminal: Terminal, header: () -> Void) -> Outcome {
        header()
        for (index, label) in items.enumerated() {
            terminal.out("  \(index + 1). \(label)")
        }
        terminal.out("  q. 退出")
        guard let line = MenuPrompt.readLine("选一个： ") else { return .quit }
        if line.lowercased() == "q" { return .quit }
        guard let index = Int(line), (1...items.count).contains(index) else { return .quit }
        return .selected(index - 1)
    }
}
