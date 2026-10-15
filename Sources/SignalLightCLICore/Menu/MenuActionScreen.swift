import Darwin
import Foundation

/// Gives command output in the menu the same frame as the menu's own screens.
final class MenuActionScreen: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: MenuActionScreen?

    private let terminal: Terminal
    private let trail: [String]
    private let lock = NSLock()
    private var body: [String] = []
    private var footer = ""
    private var progressLineIndex: Int?

    private init(terminal: Terminal, trail: [String]) {
        self.terminal = terminal
        self.trail = trail
    }

    static func begin(terminal: Terminal, trail: [String]) {
        guard CLIRuntimeContext.isMenuSession,
              terminal.isInteractive,
              isatty(STDOUT_FILENO) != 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        if let active, active.trail == trail {
            active.lock.lock()
            active.body.append("")
            active.footer = ""
            active.progressLineIndex = nil
            active.render()
            active.lock.unlock()
            return
        }
        let screen = MenuActionScreen(terminal: terminal, trail: trail)
        active = screen
        // Wait for the command's first real line instead of showing a generic
        // placeholder that can leak into an inline confirmation prompt.
    }

    static func append(_ text: String) -> Bool {
        update {
            let lines = text.components(separatedBy: "\n")
            if $0.body.isEmpty {
                $0.body = lines
            } else {
                $0.body.append(contentsOf: lines)
            }
            $0.progressLineIndex = nil
        }
    }

    static func appendProgress(_ text: String) -> Bool {
        append(text)
    }

    static func replaceProgress(_ text: String) -> Bool {
        update { screen in
            if let index = screen.progressLineIndex {
                screen.body[index] = text
            } else if screen.body.isEmpty {
                screen.body = [text]
                screen.progressLineIndex = 0
            } else {
                screen.body.append(text)
                screen.progressLineIndex = screen.body.count - 1
            }
        }
    }

    static func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    static func finishProgress() {
        _ = update { $0.progressLineIndex = nil }
    }

    static func setFooter(_ text: String) {
        _ = update { $0.footer = text }
    }

    @discardableResult
    private static func update(_ change: (MenuActionScreen) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { return false }
        active.lock.lock()
        change(active)
        active.render()
        active.lock.unlock()
        return true
    }

    static func finishForPause(terminal: Terminal, message: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { return false }
        active.lock.lock()
        active.footer = message ?? terminal.keyBar([.enter("继续"), .escape("返回")])
        active.render()
        active.lock.unlock()
        self.active = nil
        return true
    }

    static func finishWithoutPause(footer: String = "已取消") {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { return }
        active.lock.lock()
        active.footer = footer
        active.render()
        active.lock.unlock()
        self.active = nil
    }

    static func discard() {
        lock.lock()
        active = nil
        lock.unlock()
    }

    private func render() {
        ScreenLayout.paint(Self.lines(
            terminal: terminal,
            trail: trail,
            body: body,
            footer: footer
        ))
    }

    static func lines(
        terminal: Terminal,
        trail: [String],
        body: [String],
        footer: String
    ) -> [String] {
        ScreenLayout.lines(terminal: terminal, trail: trail, context: [], body: body, bar: footer)
    }
}
