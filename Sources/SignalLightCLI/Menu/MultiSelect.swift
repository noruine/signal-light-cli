import Darwin

/// A keyboard-driven checkbox picker — the interaction every user already
/// knows from `npm init`, `brew`, fzf, and installers everywhere: ↑/↓ (or
/// j/k) move the cursor, Space toggles the checkbox under it, Enter confirms
/// the whole set, q/Ctrl-C cancels.
///
/// Returns the set of checked indices, or `nil` if the user cancelled. Falls
/// back to a plain typed prompt when stdin isn't a TTY so scripts/pipes still
/// work.
enum MultiSelect {
    static func choose(
        items: [String],
        preselected: Set<Int> = [],
        terminal: Terminal,
        footerHint: String,
        header: () -> Void
    ) -> Set<Int>? {
        guard !items.isEmpty else { return [] }

        guard let original = RawMode.enter() else {
            return typedFallback(items: items, preselected: preselected, terminal: terminal, header: header)
        }
        defer {
            RawMode.restore(original)
            print("\u{1B}[?25h", terminator: "")
            fflush(stdout)
        }
        print("\u{1B}[?25l", terminator: "")
        print("\u{1B}[2J", terminator: "")

        var checked = preselected
        var cursor = 0
        while true {
            render(items: items, checked: checked, cursor: cursor, terminal: terminal, footerHint: footerHint, header: header)
            switch readKey() {
            case .up:
                cursor = (cursor - 1 + items.count) % items.count
            case .down:
                cursor = (cursor + 1) % items.count
            case .toggle:
                toggle(&checked, cursor)
            case .enter:
                return checked
            case .cancel:
                return nil
            case .other:
                break
            }
        }
    }

    private static func toggle(_ checked: inout Set<Int>, _ index: Int) {
        if checked.contains(index) {
            checked.remove(index)
        } else {
            checked.insert(index)
        }
    }

    // MARK: - Rendering

    private static func render(
        items: [String],
        checked: Set<Int>,
        cursor: Int,
        terminal: Terminal,
        footerHint: String,
        header: () -> Void
    ) {
        let clearToEOL = "\u{1B}[K"
        print("\u{1B}[H", terminator: "")
        header()
        for (index, label) in items.enumerated() {
            let box = checked.contains(index) ? "[✓]" : "[ ]"
            let line = "\(box) \(label)"
            if index == cursor {
                if terminal.useColor {
                    print("\u{1B}[7m ❯ \(line) \u{1B}[0m\(clearToEOL)")
                } else {
                    print(" ❯ \(line)\(clearToEOL)")
                }
            } else {
                print("   \(line)\(clearToEOL)")
            }
        }
        print(clearToEOL)
        print("\(terminal.dimmed(footerHint))\(clearToEOL)")
        print("\u{1B}[0J", terminator: "")
        fflush(stdout)
    }

    // MARK: - Key input

    private enum Key {
        case up, down, toggle, enter, cancel, other
    }

    private static func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .cancel }

        switch byte {
        case 0x20:  // Space
            return .toggle
        case 0x0A, 0x0D:
            return .enter
        case 0x03, 0x71, 0x51:  // Ctrl-C, q, Q
            return .cancel
        case 0x6B:  // k
            return .up
        case 0x6A:  // j
            return .down
        case 0x1B:
            switch RawMode.classifyEscape() {
            case .lone: return .cancel
            case .up: return .up
            case .down: return .down
            case .left, .right, .otherSequence: return .other
            }
        default:
            return .other
        }
    }

    // MARK: - Non-TTY fallback

    private static func typedFallback(items: [String], preselected: Set<Int>, terminal: Terminal, header: () -> Void) -> Set<Int>? {
        header()
        for (index, label) in items.enumerated() {
            let mark = preselected.contains(index) ? "[✓]" : "[ ]"
            terminal.out("  \(index + 1). \(mark) \(label)")
        }
        guard let line = MenuPrompt.readLine("请选择要启用的 Agent，以逗号分隔；直接回车保持不变，q 取消：") else { return nil }
        if line.lowercased() == "q" { return nil }
        if line.isEmpty { return preselected }
        var result: Set<Int> = []
        for token in line.split(whereSeparator: { ", ，".contains($0) }) {
            guard let n = Int(token), (1...items.count).contains(n) else { continue }
            result.insert(n - 1)
        }
        return result
    }
}
