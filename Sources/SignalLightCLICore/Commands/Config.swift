import ArgumentParser
import Foundation
import SignalLightKit

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "查看或修改灯效：每个状态怎么亮、全局亮度、总开关。",
        subcommands: [Show.self, Set.self, Brightness.self, On.self, Off.self, Reset.self],
        defaultSubcommand: Show.self
    )

    // MARK: show

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "查看当前灯效配置。")

        @OptionGroup var globals: GlobalOptions

        @Flag(help: "以 JSON 格式输出。")
        var json: Bool = false

        func run() async throws {
            let paths = SignalLightDaemonPaths.current()
            let settings = try SignalLightStores.loadSettings(from: paths.settingsJSONURL)

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try encoder.encode(settings), encoding: .utf8) ?? "{}")
                return
            }

            let terminal = globals.makeTerminal()
            terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))灯效配置")
            terminal.out("    总开关    \(settings.enabled ? terminal.success("开") : terminal.dimmed("关"))")
            terminal.out("    亮度      \(settings.clampedBrightness)%")
            terminal.out("    ——")
            for bucket in SignalLightBucketDisplay.orderedForDisplay {
                let effect = settings.effect(for: bucket)
                terminal.out("    \(SignalLightBucketDisplay.paddedName(bucket))  \(ConfigFormat.describe(effect))")
            }
            terminal.out("")
            terminal.progress("修改示例：signal-light config set running --type blink --colors Y --interval 300")
        }
    }

    // MARK: set

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "设置某个状态的灯效（只改指定字段，其余保持不变）。"
        )

        @OptionGroup var globals: GlobalOptions

        @Argument(help: "状态：idle（空闲）/ running（运行中）/ needsApproval（等待审批）/ needsAnswer（等待回答）。")
        var bucket: String

        @Option(help: "灯效类型：solid（常亮）/ blink（闪烁）/ cycle（循环）/ breathe（呼吸）。")
        var type: String?

        @Option(help: "参与的颜色，红黄绿用 R/Y/G，如 RYG 或 Y。")
        var colors: String?

        @Option(help: "变化间隔（毫秒），solid 之外的类型需要 > 0。")
        var interval: Int?

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()
            let targetBucket = try SignalLightBucketDisplay.parse(bucket)

            guard type != nil || colors != nil || interval != nil else {
                throw CLIError(
                    "没说改哪里。至少给一个 --type / --colors / --interval，比如：signal-light config set \(bucket) --type blink --colors Y --interval 300",
                    exitCode: .usage
                )
            }

            var settings = try SignalLightStores.loadSettings(from: paths.settingsJSONURL)
            var effect = settings.effect(for: targetBucket)

            if let type {
                guard let parsed = SignalLightEffectType(rawValue: type.lowercased()) else {
                    throw CLIError("没有这种灯效 “\(type)”。可以填：solid / blink / cycle / breathe。", exitCode: .usage)
                }
                effect.type = parsed
            }
            if let colors {
                effect.colors = try ConfigFormat.parseColors(colors)
            }
            if let interval {
                guard interval >= 0 else {
                    throw CLIError("间隔不能是负数。", exitCode: .usage)
                }
                effect.intervalMs = interval
            }

            if effect.type != .solid, effect.intervalMs <= 0 {
                throw CLIError("\(effect.type.rawValue) 类型需要 --interval 大于 0 的毫秒值。", exitCode: .usage)
            }

            settings.effects[targetBucket] = effect
            try SignalLightSettingsStore.save(settings, to: paths.settingsJSONURL)

            terminal.out("\(terminal.emoji(CLIGlyph.success))\(SignalLightBucketDisplay.name(targetBucket))灯效已更新：\(ConfigFormat.describe(effect))")
            ConfigReloadNotice.emit(terminal: terminal, paths: paths)
        }
    }

    // MARK: brightness

    struct Brightness: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "brightness", abstract: "设置全局亮度（0–100）。")

        @OptionGroup var globals: GlobalOptions

        @Argument(help: "亮度百分比，0–100。")
        var percent: Int

        func run() async throws {
            guard (0...100).contains(percent) else {
                throw CLIError("亮度只能是 0–100。", exitCode: .usage)
            }
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()
            var settings = try SignalLightStores.loadSettings(from: paths.settingsJSONURL)
            settings.brightness = percent
            try SignalLightSettingsStore.save(settings, to: paths.settingsJSONURL)
            terminal.out("\(terminal.emoji(CLIGlyph.success))亮度已设为 \(percent)%。")
            ConfigReloadNotice.emit(terminal: terminal, paths: paths)
        }
    }

    // MARK: on / off

    struct On: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "on", abstract: "打开信号灯（总开关）。")
        @OptionGroup var globals: GlobalOptions
        func run() async throws { try ConfigToggle.set(enabled: true, globals: globals) }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "熄灭信号灯（总开关，服务继续运行）。")
        @OptionGroup var globals: GlobalOptions
        func run() async throws { try ConfigToggle.set(enabled: false, globals: globals) }
    }

    // MARK: reset

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset", abstract: "恢复所有灯效到默认值。")

        @OptionGroup var globals: GlobalOptions

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()
            try SignalLightSettingsStore.save(.default, to: paths.settingsJSONURL)
            terminal.out("\(terminal.emoji(CLIGlyph.success))已恢复默认灯效配置。")
            ConfigReloadNotice.emit(terminal: terminal, paths: paths)
        }
    }
}

private enum ConfigToggle {
    static func set(enabled: Bool, globals: GlobalOptions) throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()
        var settings = try SignalLightStores.loadSettings(from: paths.settingsJSONURL)
        settings.enabled = enabled
        try SignalLightSettingsStore.save(settings, to: paths.settingsJSONURL)
        terminal.out("\(terminal.emoji(CLIGlyph.success))信号灯已\(enabled ? "打开" : "熄灭")。")
        ConfigReloadNotice.emit(terminal: terminal, paths: paths)
    }
}

/// After any settings edit, nudge a running daemon to reload live and tell the
/// user which happened, so the effect of their change is never a mystery.
private enum ConfigReloadNotice {
    static func emit(terminal: Terminal, paths: SignalLightDaemonPaths) {
        if DaemonReload.reloadIfRunning(paths: paths) {
            terminal.progress("已通知服务，马上生效。")
        } else {
            terminal.progress("已保存，服务下次启动时生效。")
        }
    }
}

enum SignalLightBucketDisplay {
    static let orderedForDisplay: [SignalLightBucket] = [.idle, .running, .needsApproval, .needsAnswer]

    /// Display name without padding; column layouts pad via `paddedName(_:)`.
    static func name(_ bucket: SignalLightBucket) -> String {
        switch bucket {
        case .idle: "空闲"
        case .running: "运行中"
        case .needsApproval: "等待审批"
        case .needsAnswer: "等待回答"
        }
    }

    /// Name padded to the widest label so `config show` columns line up.
    static func paddedName(_ bucket: SignalLightBucket) -> String {
        name(bucket).padding(toLength: 4, withPad: " ", startingAt: 0)
    }

    /// Emoji paired with each bucket in menus.
    static func emoji(_ bucket: SignalLightBucket) -> String {
        switch bucket {
        case .idle: "😴"
        case .running: "🏃"
        case .needsApproval: "🙋"
        case .needsAnswer: "❓"
        }
    }

    /// Human-readable name for a raw `state.json` bucket value, falling back
    /// to the raw value for unknown strings.
    static func name(forRaw raw: String) -> String {
        SignalLightBucket(rawValue: raw).map(name) ?? raw
    }

    static func parse(_ raw: String) throws -> SignalLightBucket {
        guard let bucket = SignalLightBucket(rawValue: raw) else {
            throw CLIError(
                "不认识这个状态 “\(raw)”。可以填：idle / running / needsApproval / needsAnswer。",
                exitCode: .usage
            )
        }
        return bucket
    }
}

enum ConfigFormat {
    static func parseColors(_ raw: String) throws -> [SignalLightColor] {
        let letters = raw.uppercased().filter { !",， ".contains($0) }
        guard !letters.isEmpty else {
            throw CLIError("颜色不能空，用 R/Y/G，比如 RYG。", exitCode: .usage)
        }
        var result: [SignalLightColor] = []
        for character in letters {
            guard let color = SignalLightColor(commandLetter: character) else {
                throw CLIError("没有这个颜色 “\(character)”，只能填 R（红）/ Y（黄）/ G（绿）。", exitCode: .usage)
            }
            result.append(color)
        }
        return result
    }

    /// The single shared source for a color's Chinese name across the CLI
    /// (config listing, calibration prompts, …), so the mapping isn't
    /// re-spelled per command.
    static func colorName(_ color: SignalLightColor) -> String {
        switch color {
        case .red: "红"
        case .yellow: "黄"
        case .green: "绿"
        }
    }

    /// Chinese name for an effect type, shared by the config listing and the
    /// interactive type picker so the two never drift.
    static func typeName(_ type: SignalLightEffectType) -> String {
        switch type {
        case .solid: "常亮"
        case .blink: "闪烁"
        case .cycle: "循环"
        case .breathe: "呼吸"
        }
    }

    static func describe(_ effect: SignalLightEffect) -> String {
        let colorNames = effect.colors.map(colorName).joined()
        let interval = effect.type == .solid ? "" : " · \(effect.intervalMs)ms"
        return "\(colorNames.isEmpty ? "无色" : colorNames) \(typeName(effect.type))\(interval)"
    }
}
