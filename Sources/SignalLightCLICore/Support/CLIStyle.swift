import Foundation

/// Shared vocabulary for the small set of decorative bits every command
/// reuses (status dots, emoji glyphs), kept in one place so the "friendly
/// but not noisy" tone stays consistent across `pair`/`install`/`status`/etc.
public enum CLIGlyph {
    public static let search = "🔍"
    public static let success = "✅"
    public static let package = "📦"
    public static let cleanup = "🧹"
    public static let signing = "🔏"
    public static let upgrade = "🆙"
    public static let warning = "⚠️"
    public static let trafficLight = "🚦"
    public static let start = "▶️"
    public static let stop = "⏸️"
    public static let restart = "🔄"
    public static let effect = "🎨"
    public static let agent = "🪝"
    public static let device = "📡"
    public static let calibrate = "🎯"
    public static let firmware = "⬆️"
    public static let doctor = "🩺"
    public static let logs = "📜"
    public static let next = "👉"
    public static let rename = "✏️"
    public static let unpair = "🗑️"
    public static let autostart = "⏰"
    public static let power = "🔌"
    public static let brightness = "💡"
    public static let reset = "♻️"
}

/// One hint of a screen's bottom bar. A screen only chooses *which* hints it
/// shows — move/confirm/escape where they apply, nothing where they don't —
/// while the wording, spacing and order are fixed here so they can't drift.
public enum KeyHint {
    case move
    case spaceToggle
    case enter(String)
    case escape(String)

    var text: String {
        switch self {
        case .move:
            "↑/↓ 移动"
        case .spaceToggle:
            "Space 勾选"
        case let .enter(action):
            "Enter \(action)"
        case let .escape(action):
            "Esc \(action)"
        }
    }
}

extension Terminal {
    /// A colored `●`/`○` status dot for booleans like "service running" /
    /// "device connected" — degrades to plain `[on]`/`[off]` when undecorated.
    public func statusDot(_ isOn: Bool) -> String {
        guard useColor else { return isOn ? "[on]" : "[off]" }
        return isOn ? success("●") : dimmed("○")
    }

    /// `🚦  信号灯 › 诊断 › 查看文件清单` (root alone: `🚦  信号灯`) — the fixed
    /// top line of every screen: one glyph, plain segment names, one
    /// separator style. Only the body of a screen is allowed to differ.
    public func menuBreadcrumb(_ trail: [String] = []) -> String {
        let segments = ["信号灯"] + trail
        return "\(emoji(CLIGlyph.trafficLight))\(segments.joined(separator: " \(dimmed("›")) "))"
    }

    /// The fixed bottom line of a screen: `↑/↓ 移动 · Enter 确认 · Esc 返回`.
    public func keyBar(_ hints: [KeyHint]) -> String {
        hints.map(\.text).joined(separator: " · ")
    }
}

/// The one shell every screen renders through — think of it as the layout:
///
///     breadcrumb (or none, when the screen continues another's)
///     (blank)
///     context lines (body info: 版本 / 状态 / 第 1 步 …; plain color)
///     (blank)
///     body            ← the list or output; the only part that varies
///     (blank)
///     key bar         ← the footer, the one dimmed line
///
/// All spacing and color roles live here alone, so no screen can drift from
/// the others no matter which painter (list, checkbox, confirm, scan) draws
/// it: plain text is body, only the footer bar is dimmed. The breadcrumb is
/// menu chrome — a bare CLI run passes no trail and stays Unix-plain.
public enum ScreenLayout {
    /// Paints a shell over the previous frame: home, then every line cleared
    /// to EOL (a shrinking reverse-video highlight would otherwise leave a
    /// stray block), then erase whatever a taller frame left below.
    public static func paint(_ lines: [String], emit: (String) -> Void = { print($0, terminator: "") }) {
        emit("\u{1B}[H")
        for line in lines {
            emit(line + "\u{1B}[K\n")
        }
        emit("\u{1B}[0J")
        fflush(stdout)
    }

    /// Retires the finished step's frame so the next one starts from a clean
    /// screen — menu chrome only: in a session that keeps going, a stale frame
    /// would otherwise sit under the next step and read as current. Bare CLI
    /// runs never clear; their scrollback is the record.
    public static func beginStep(emit: (String) -> Void = { print($0, terminator: "") }) {
        emit("\u{1B}[2J\u{1B}[H")
        fflush(stdout)
    }

    public static func lines(
        terminal: Terminal,
        trail: [String]?,
        context: [String],
        body: [String],
        bar: String
    ) -> [String] {
        var lines: [String] = []
        if let trail {
            lines.append(terminal.menuBreadcrumb(trail))
        }
        if !context.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(contentsOf: context)
        }
        if !lines.isEmpty {
            // The separator blank only exists when something sits above the
            // body; a screen continuing another (a confirm) starts right in.
            lines.append("")
        }
        lines.append(contentsOf: body)
        lines.append("")
        lines.append(terminal.dimmed(bar))
        return lines
    }
}
