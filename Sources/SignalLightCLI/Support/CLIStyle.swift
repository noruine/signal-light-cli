
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

extension Terminal {
    /// A colored `●`/`○` status dot for booleans like "service running" /
    /// "device connected" — degrades to plain `[on]`/`[off]` when undecorated.
    public func statusDot(_ isOn: Bool) -> String {
        guard useColor else { return isOn ? "[on]" : "[off]" }
        return isOn ? success("●") : dimmed("○")
    }
}
