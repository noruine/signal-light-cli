import ArgumentParser
import Darwin
import Foundation

/// Small prompt helpers shared by the interactive menu and its `config`
/// submenu. Kept separate from `Confirm` (which is specifically y/n) since
/// these are numbered-choice and free-text prompts.
enum MenuPrompt {
    /// Reads a line from stdin after writing `question` to stderr. Returns
    /// `nil` to mean "cancel / go back" — on EOF, Ctrl-C/Ctrl-D, or **Esc**,
    /// so no prompt can ever trap the user into having to type a valid value
    /// just to escape it.
    ///
    /// On a TTY this runs a small raw-mode line editor (printable input +
    /// Backspace) precisely so a lone Esc can be told apart from an arrow-key
    /// escape sequence (`Esc [ A`) — cooked `readLine` can't see Esc at all
    /// until Enter. Off a TTY it falls back to plain `readLine`.
    static func readLine(_ question: String) -> String? {
        // Enter raw mode *before* drawing the prompt: this both suppresses
        // echo for the whole prompt lifetime and (via TCSAFLUSH) drops any
        // keys mashed before the prompt appeared, so a stray Esc typed in the
        // gap can't get cooked-echoed as `^[` or acted on prematurely.
        guard let original = RawMode.enter() else {
            FileHandle.standardError.write(Data(question.utf8))
            guard let line = Swift.readLine(strippingNewline: true) else { return nil }
            return line.trimmingCharacters(in: .whitespaces)
        }
        defer { RawMode.restore(original) }
        FileHandle.standardError.write(Data(question.utf8))

        var buffer: [UInt8] = []
        while true {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { writeStderr("\n"); return nil }

            switch byte {
            case 0x0A, 0x0D:  // Enter
                writeStderr("\n")
                return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            case 0x03, 0x04:  // Ctrl-C, Ctrl-D
                writeStderr("\n")
                return nil
            case 0x7F, 0x08:  // Backspace / Delete
                if !buffer.isEmpty {
                    buffer.removeLast()
                    writeStderr("\u{8} \u{8}")  // erase last glyph on screen
                }
            case 0x1B:  // Esc — cancel, unless it's the lead byte of an arrow/CSI sequence
                if case .lone = RawMode.classifyEscape() {
                    writeStderr("\n")
                    return nil
                }
                // Arrow/other sequence in a text field: ignore (no cursor
                // movement support), don't cancel.
            default:
                // Echo any printable byte (incl. UTF-8 continuation bytes, so
                // multibyte input still shows) — control bytes are ignored.
                if byte >= 0x20 {
                    buffer.append(byte)
                    var echo = byte
                    _ = write(STDERR_FILENO, &echo, 1)
                }
            }
        }
    }

    private static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Free-text prompt with a default shown inline; a bare Enter keeps it,
    /// Esc cancels (see `readLine`).
    static func text(_ question: String, default defaultValue: String?) -> String? {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        guard let line = readLine("\(question)\(suffix)（Esc 取消）：") else { return nil }
        if line.isEmpty { return defaultValue }
        return line
    }

    /// An integer prompt with a default, re-asking until the input parses as
    /// an integer rather than silently falling back — a mistyped brightness
    /// value should never silently become "0" or the old value. Range
    /// checking is left to the command the value is passed to (e.g.
    /// `config brightness` rejects anything outside 0–100), so the same
    /// validation isn't duplicated in two places.
    static func integer(_ question: String, default defaultValue: Int) -> Int? {
        while true {
            guard let raw = text(question, default: String(defaultValue)) else { return nil }
            if let value = Int(raw) { return value }
            FileHandle.standardError.write(Data("请输入整数。\n".utf8))
        }
    }

    /// Blocks until the user presses Enter, so command output stays on screen
    /// long enough to read before the menu redraws over it. EOF just returns.
    ///
    /// Reads in cbreak mode rather than via cooked `readLine`: at a cooked
    /// prompt an impatient arrow-key press echoes its raw escape bytes (`^[[B`)
    /// onto the line. With echo off nothing stray is printed, and only Enter
    /// (or Ctrl-C/Ctrl-D, treated the same as "continue") unblocks — every
    /// other key is silently swallowed, which is the behavior the user
    /// expects once a menu has "captured" the keyboard. Falls back to a line
    /// read when stdin isn't a TTY.
    static func pause(_ terminal: Terminal, message: String = "按回车继续") {
        FileHandle.standardError.write(Data(terminal.dimmed(message).utf8))

        guard let original = RawMode.enter() else {
            _ = Swift.readLine()
            FileHandle.standardError.write(Data("\n".utf8))
            return
        }
        defer {
            RawMode.restore(original)
            FileHandle.standardError.write(Data("\n".utf8))
        }

        var byte: UInt8 = 0
        while read(STDIN_FILENO, &byte, 1) == 1 {
            switch byte {
            case 0x0A, 0x0D, 0x03, 0x04:  // Enter, Ctrl-C, Ctrl-D
                return
            default:
                continue  // discard arrow keys and any other keypress
            }
        }
    }
}

/// One selectable line in a menu: its label, what running it does, and
/// whether to wait for a keypress afterward. `pausesAfter` is false for
/// items that open their own sub-menu (which manages its own screen), so the
/// user isn't asked to press Enter twice.
struct MenuChoice {
    let label: String
    let pausesAfter: Bool
    let run: () async -> Void
    /// Evaluated after `run` completes: return true to leave the menu loop
    /// entirely rather than redrawing. Used by `uninstall`, which removes the
    /// tool itself — staying in a menu whose backing binary was just deleted
    /// makes no sense. Gated on real post-action state (not a static flag) so
    /// a *cancelled* destructive action correctly keeps the user in the menu.
    let shouldExitAfter: () -> Bool

    init(
        _ label: String,
        pausesAfter: Bool = true,
        shouldExitAfter: @escaping () -> Bool = { false },
        run: @escaping () async -> Void
    ) {
        self.label = label
        self.pausesAfter = pausesAfter
        self.shouldExitAfter = shouldExitAfter
        self.run = run
    }
}

/// The shared render→pick→run→pause loop behind every interactive menu. Keeps
/// the arrow-key picker, the "→ 你选了什么" echo, and the post-action pause in
/// one place so the main menu and each sub-menu behave identically.
/// `buildItems` is re-evaluated every iteration so item labels/availability
/// reflect state changes from the previous action.
enum MenuLoop {
    static func run(
        terminal: Terminal,
        footerHint: String = "↑/↓ 移动 · 回车确认 · Esc 返回",
        header: @escaping () -> Void,
        buildItems: () -> [MenuChoice]
    ) async {
        while true {
            let items = buildItems()
            let outcome = MenuSelector.choose(items: items.map(\.label), terminal: terminal, footerHint: footerHint, header: header)
            guard case let .selected(index) = outcome else { return }

            let item = items[index]
            // Start every action on a clean screen. The picker clears when it
            // redraws, but the *action's* own output would otherwise pile up
            // under the previous step's — fine for a one-shot command, cramped
            // in a session that keeps going.
            print("\u{1B}[2J\u{1B}[H", terminator: "")
            fflush(stdout)
            await item.run()

            // Exit before pausing so the final output (e.g. uninstall's
            // summary) stays on screen and the program ends cleanly, with no
            // pointless "press Enter" on the way out.
            if item.shouldExitAfter() { return }
            // A cancel said its one line already; asking for Enter on top of
            // it is exactly the ceremony the user just stopped.
            if item.pausesAfter, !CLIRuntimeContext.consumeCancelledCommand() {
                MenuPrompt.pause(terminal)
            }
        }
    }
}

/// Executes a fully-formed `signal-light` argv from inside the interactive
/// menu, going through the exact same `ParsableCommand` tree the top-level
/// binary uses — so the menu is a pure shell over real commands, never a
/// second, divergent implementation of the same logic.
enum MenuCommandRunner {
    @discardableResult
    static func run(_ arguments: [String], terminal: Terminal) async -> Bool {
        do {
            var command = try SignalLightCLI.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return true
        } catch let cliError as CLIError {
            terminal.errorLine(cliError.message)
            return false
        } catch is CleanExit {
            // Menu-built argv never requests --help/--version, but guard
            // against it defensively rather than letting it fall through to
            // the generic branch below and print a confusing error.
            return true
        } catch {
            terminal.errorLine("\(error)")
            return false
        }
    }
}
