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
        // echo for the whole prompt lifetime and drops any keys mashed
        // before the prompt appeared, so a stray Esc typed in the gap can't
        // get cooked-echoed as `^[` or acted on prematurely.
        RawMode.discardPendingInput()
        guard let original = RawMode.enter() else {
            FileHandle.standardError.write(Data(question.utf8))
            guard let line = Swift.readLine(strippingNewline: true) else { return nil }
            return line.trimmingCharacters(in: .whitespaces)
        }
        defer { RawMode.restore(original) }
        FileHandle.standardError.write(Data(question.utf8))
        return editLineBytes()
    }

    /// The raw-mode byte loop both prompt styles share: echo printable input
    /// and Backspace from wherever the cursor sits; Enter ends the line and
    /// returns it, Esc / Ctrl-C / Ctrl-D / EOF end it as `nil`.
    private static func editLineBytes() -> String? {
        var buffer = MenuLineBuffer()
        while true {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { writeStderr("\n"); return nil }

            switch byte {
            case 0x0A, 0x0D:  // Enter
                writeStderr("\n")
                return buffer.value.trimmingCharacters(in: .whitespaces)
            case 0x03, 0x04:  // Ctrl-C, Ctrl-D
                writeStderr("\n")
                return nil
            case 0x7F, 0x08:  // Backspace / Delete
                let columns = buffer.deleteLastCharacter()
                if columns > 0 {
                    writeStderr(String(repeating: "\u{8} \u{8}", count: columns))
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
    /// Esc cancels (see `readLine`). Inside the menu the prompt is a screen
    /// like every other one — breadcrumb, the question as context, a `❯`
    /// edit row, the key bar; a bare CLI run keeps the plain inline prompt.
    /// `note` is a retry line (e.g. "not an integer") shown above the prompt
    /// in both styles.
    static func text(
        _ question: String,
        default defaultValue: String?,
        note: String? = nil,
        terminal: Terminal
    ) -> String? {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""

        guard CLIRuntimeContext.isMenuSession else {
            if let note { writeStderr("\(note)\n") }
            guard let line = readLine("\(question)\(suffix)（Esc 取消）：") else { return nil }
            return line.isEmpty ? defaultValue : line
        }

        RawMode.discardPendingInput()
        guard let original = RawMode.enter() else {
            if let note { writeStderr("\(note)\n") }
            FileHandle.standardError.write(Data("\(question)\(suffix)（Esc 取消）：".utf8))
            guard let line = Swift.readLine(strippingNewline: true) else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? defaultValue : trimmed
        }
        defer { RawMode.restore(original) }

        var context = ["\(question)\(suffix)"]
        if let note { context.append(note) }
        ScreenLayout.beginStep()
        ScreenLayout.paint(ScreenLayout.lines(
            terminal: terminal,
            trail: CLIRuntimeContext.menuTrail.isEmpty ? nil : CLIRuntimeContext.menuTrail,
            context: context,
            body: [" "],
            bar: terminal.keyBar([.enter("确认"), .escape("取消")])
        ))
        // The paint leaves the cursor under the key bar; hop onto the edit
        // row and land the `❯` marker — the editor echoes from the cursor.
        writeStderr("\u{1B}[3A\r ❯ ")
        guard let value = editLineBytes() else { return nil }
        writeStderr("\u{1B}[2B")
        return value.isEmpty ? defaultValue : value
    }

    /// An integer prompt with a default, re-asking until the input parses as
    /// an integer rather than silently falling back — a mistyped brightness
    /// value should never silently become "0" or the old value. Range
    /// checking is left to the command the value is passed to (e.g.
    /// `config brightness` rejects anything outside 0–100), so the same
    /// validation isn't duplicated in two places.
    static func integer(_ question: String, default defaultValue: Int, terminal: Terminal) -> Int? {
        var note: String?
        while true {
            guard let raw = text(question, default: String(defaultValue), note: note, terminal: terminal) else { return nil }
            if let value = Int(raw) { return value }
            note = "请输入整数。"
        }
    }

    /// Blocks until the user presses Enter (or Esc, or Ctrl-C/Ctrl-D), so
    /// command output stays on screen long enough to read before the menu
    /// redraws over it. EOF just returns. The default message is the
    /// canonical pause bar `Enter 继续 · Esc 返回` — the two keys it
    /// answers to — printed under a blank line so the bottom spacing
    /// matches every other screen's shell.
    ///
    /// Reads in cbreak mode rather than via cooked `readLine`: at a cooked
    /// prompt an impatient arrow-key press echoes its raw escape bytes (`^[[B`)
    /// onto the line. With echo off nothing stray is printed, and only Enter,
    /// Esc, or Ctrl-C/Ctrl-D unblocks — every other key is silently
    /// swallowed, which is the behavior the user expects once a menu has
    /// "captured" the keyboard. Falls back to a line read when stdin isn't a
    /// TTY.
    static func pause(_ terminal: Terminal, message: String? = nil) {
        let pageAlreadyHasFooter = MenuActionScreen.finishForPause(terminal: terminal, message: message)
        if !pageAlreadyHasFooter {
            FileHandle.standardError.write(Data(("\n" + terminal.dimmed(message ?? terminal.keyBar([.enter("继续"), .escape("返回")]))).utf8))
        }

        // A key mashed while the action ran must not answer the pause.
        RawMode.discardPendingInput()
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
            case 0x1B:  // Esc — the site-wide "back", answered here too
                if case .lone = RawMode.classifyEscape() {
                    return
                }
            default:
                continue  // discard arrow keys and any other keypress
            }
        }
    }
}

/// Stores the bytes echoed by the line editor and removes whole Unicode
/// characters when Backspace is pressed, even though input arrives by byte.
struct MenuLineBuffer {
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
        0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
        0x1F300...0x1FAFF, 0x20000...0x3FFFD,
    ]

    private var bytes: [UInt8] = []

    var value: String {
        String(decoding: bytes, as: UTF8.self)
    }

    mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    /// Removes one extended grapheme cluster and returns its terminal width.
    /// An incomplete UTF-8 sequence is reduced one byte at a time.
    mutating func deleteLastCharacter() -> Int {
        guard let decoded = String(bytes: bytes, encoding: .utf8), let character = decoded.last else {
            guard !bytes.isEmpty else { return 0 }
            bytes.removeLast()
            return 1
        }

        bytes = Array(decoded.dropLast().utf8)
        let scalars = Array(character.unicodeScalars)
        if scalars.contains(where: { $0.value == 0x200D }) { return 2 }
        if scalars.filter({ (0x1F1E6...0x1F1FF).contains($0.value) }).count == 2 { return 2 }

        let width = scalars.map(Self.scalarWidth).max() ?? 0
        let displayWidth = scalars.contains(where: { $0.value == 0xFE0F }) ? max(2, width) : width
        return Int(max(1, displayWidth))
    }

    private static func scalarWidth(_ scalar: Unicode.Scalar) -> Int32 {
        let value = scalar.value
        if Self.wideRanges.contains(where: { $0.contains(value) }) { return 2 }
        return max(0, wcwidth(wchar_t(value)))
    }
}

/// One selectable line in a menu: its label, what running it does, and
/// whether to wait for a keypress afterward. `pausesAfter` is false for
/// items that open their own sub-menu (which manages its own screen), so the
/// user isn't asked to press Enter twice.
struct MenuChoice {
    let label: String
    /// The plain name this item carries into breadcrumbs — no glyph, no
    /// decoration — so a result screen reads `🚦  信号灯 › 诊断 › 查看文件清单`.
    let crumb: String
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
        crumb: String,
        pausesAfter: Bool = true,
        shouldExitAfter: @escaping () -> Bool = { false },
        run: @escaping () async -> Void
    ) {
        self.label = label
        self.crumb = crumb
        self.pausesAfter = pausesAfter
        self.shouldExitAfter = shouldExitAfter
        self.run = run
    }
}

/// The shared render→pick→run→pause loop behind every interactive menu.
/// Draws the one fixed frame every screen shares — breadcrumb on top, key bar
/// on the bottom, each composed in `Terminal` — and runs the same pick →
/// action → pause behavior, so pages differ only in their body. The
/// breadcrumb follows an action onto its result screen, one segment deeper.
/// `buildItems` is re-evaluated every iteration so item labels/availability
/// reflect state changes from the previous action.
enum MenuLoop {
    static func run(
        terminal: Terminal,
        page: String? = nil,
        escapeHint: KeyHint = .escape("返回"),
        refreshInterval: TimeInterval? = nil,
        context: @escaping () -> [String],
        buildItems: () -> [MenuChoice]
    ) async {
        while true {
            let items = buildItems()
            let outcome = MenuSelector.choose(
                items: items.map(\.label),
                terminal: terminal,
                trail: page.map { [$0] } ?? [],
                context: context,
                footerHint: terminal.keyBar([.move, .enter("确认"), escapeHint]),
                refreshInterval: refreshInterval
            )
            guard case let .selected(index) = outcome else { return }

            let item = items[index]
            // Start every action on a clean screen. The picker clears when it
            // redraws, but the *action's* own output would otherwise pile up
            // under the previous step's — fine for a one-shot command, cramped
            // in a session that keeps going.
            ScreenLayout.beginStep()
            // The frame follows the action onto its result screen: same
            // breadcrumb, one segment deeper, so output never floats without
            // a place.
            CLIRuntimeContext.menuTrail = (page.map { [$0] } ?? []) + [item.crumb]
            terminal.out(terminal.menuBreadcrumb(CLIRuntimeContext.menuTrail))
            terminal.out("")
            await item.run()
            // Keys mashed while the action ran (nothing was reading them)
            // must not fire on the screen that comes next; drop them once,
            // here at the boundary.
            RawMode.discardPendingInput()
            CLIRuntimeContext.menuTrail = []

            // Exit before pausing so the final output (e.g. uninstall's
            // summary) stays on screen and the program ends cleanly, with no
            // pointless "press Enter" on the way out.
            if item.shouldExitAfter() {
                MenuActionScreen.finishWithoutPause(footer: "已完成")
                CLIRuntimeContext.menuTrail = []
                return
            }
            let ending = CLIRuntimeContext.consumeCommandEnding()
            if item.pausesAfter {
                switch ending {
                case .announcedCancel:
                    MenuActionScreen.finishWithoutPause()
                    // The cancel line needs a beat on screen before the
                    // redraw wipes it, or it reads as a flicker of
                    // unexplained text.
                    try? await Task.sleep(for: .milliseconds(700))
                case .silentCancel:
                    MenuActionScreen.discard()
                    break  // the answer to the question was the statement
                case .completed:
                    MenuPrompt.pause(terminal)
                    // The pause was its own boundary too: a second Enter
                    // mashed right after dismissing it must not re-fire
                    // this item.
                    RawMode.discardPendingInput()
                }
            } else {
                MenuActionScreen.discard()
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
        MenuActionScreen.begin(terminal: terminal, trail: CLIRuntimeContext.menuTrail)
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
