
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
            "空格 勾选"
        case let .enter(action):
            "回车 \(action)"
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
    public func menuBreadcrumb(_ page: String? = nil, _ item: String? = nil) -> String {
        var segments = ["信号灯"]
        if let page {
            segments.append(page)
        }
        if let item {
            segments.append(item)
        }
        return "\(emoji(CLIGlyph.trafficLight))\(segments.joined(separator: " \(dimmed("›")) "))"
    }

    /// The fixed bottom line of a screen: `↑/↓ 移动 · 回车 确认 · Esc 返回`.
    public func keyBar(_ hints: [KeyHint]) -> String {
        hints.map(\.text).joined(separator: " · ")
    }
}
