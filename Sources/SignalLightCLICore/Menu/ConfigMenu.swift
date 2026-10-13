import Foundation
import SignalLightKit

/// The 「灯效设置」 sub-page: the numbered-choice equivalent of
/// `config set/brightness/on/off/reset`. Every edit ends up calling
/// `MenuCommandRunner.run` with the same argv a script would pass on the
/// command line.
enum ConfigMenu {
    static func run(terminal: Terminal) async {
        let paths = SignalLightDaemonPaths.current()

        await MenuLoop.run(
            terminal: terminal,
            page: "灯效设置",
            context: {
                ["选择状态并调整灯效，改动可直接在灯上预览。"]
            },
            buildItems: {
                let settings = (try? SignalLightSettingsStore.load(from: paths.settingsJSONURL)) ?? .default
                var items: [MenuChoice] = SignalLightBucketDisplay.orderedForDisplay.map { bucket in
                    let label = "\(SignalLightBucketDisplay.emoji(bucket)) \(SignalLightBucketDisplay.name(bucket))  \(ConfigFormat.describe(settings.effect(for: bucket)))"
                    // The edit flow pauses only when something actually
                    // happened — cancelling out of a picker returns to the
                    // list instantly instead of asking for a pointless Enter.
                    return MenuChoice(label, crumb: SignalLightBucketDisplay.name(bucket), pausesAfter: false) {
                        await editBucket(bucket, paths: paths, terminal: terminal)
                    }
                }
                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.brightness))全局亮度  当前 \(settings.clampedBrightness)%", crumb: "全局亮度", pausesAfter: false) {
                    await editBrightness(current: settings.clampedBrightness, terminal: terminal)
                })
                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.power))\(settings.enabled ? "关闭信号灯" : "打开信号灯")", crumb: settings.enabled ? "关闭信号灯" : "打开信号灯") {
                    await MenuCommandRunner.run(["config", settings.enabled ? "off" : "on"], terminal: terminal)
                })
                items.append(MenuChoice("\(terminal.emoji(CLIGlyph.reset))恢复默认灯效", crumb: "恢复默认灯效") {
                    await confirmReset(terminal: terminal)
                })
                return items
            }
        )
    }

    private static func editBucket(_ bucket: SignalLightBucket, paths: SignalLightDaemonPaths, terminal: Terminal) async {
        guard let settings = try? SignalLightSettingsStore.load(from: paths.settingsJSONURL) else {
            terminal.errorLine("灯效配置读取失败。")
            return
        }
        let current = settings.effect(for: bucket)
        let bucketName = SignalLightBucketDisplay.name(bucket)

        guard let type = pickType(current: current, bucketName: bucketName, terminal: terminal) else { return }
        guard let colors = pickColors(current: current, bucketName: bucketName, terminal: terminal) else { return }

        var interval = 0
        if type != .solid {
            let fallbackInterval = current.intervalMs > 0 ? current.intervalMs : 1000
            terminal.out("")
            guard let value = MenuPrompt.integer("变化快慢（毫秒，数字越小越快）", default: fallbackInterval) else { return }
            interval = value
        }

        let edited = SignalLightEffect(type: type, colors: colors, intervalMs: interval)
        await previewIfWanted(edited, paths: paths, terminal: terminal)

        let colorsRaw = colors.map(\.commandLetter).joined()
        var argv = ["config", "set", bucket.rawValue, "--type", type.rawValue, "--colors", colorsRaw]
        if type != .solid {
            argv += ["--interval", String(interval)]
        }
        await MenuCommandRunner.run(argv, terminal: terminal)
        MenuPrompt.pause(terminal)
    }

    /// Effect type via an arrow-key list (no typing a code to look up). The
    /// current value is pre-highlighted so a bare Enter keeps it.
    private static func pickType(current: SignalLightEffect, bucketName: String, terminal: Terminal) -> SignalLightEffectType? {
        let types: [SignalLightEffectType] = [.solid, .blink, .cycle, .breathe]
        let labels = types.map { "\(ConfigFormat.typeName($0))  \(terminal.dimmed($0.rawValue))" }
        let startIndex = types.firstIndex(of: current.type) ?? 0
        let outcome = MenuSelector.choose(
            items: labels,
            terminal: terminal,
            trail: ["灯效设置", bucketName],
            context: {
                [
                    "第 1 步：怎么亮",
                    "当前：\(ConfigFormat.describe(current))",
                ]
            },
            footerHint: terminal.keyBar([.move, .enter("确认"), .escape("取消")]),
            initialIndex: startIndex
        )
        guard case let .selected(index) = outcome else { return nil }
        return types[index]
    }

    /// Colors via a checkbox list (Space to toggle 红/黄/绿), pre-checked to
    /// the current selection. Fixed 红→黄→绿 order for the chosen subset; the
    /// 专业路 `config set --colors GYR` still allows an arbitrary cycle order
    /// for the rare case that needs it.
    private static func pickColors(current: SignalLightEffect, bucketName: String, terminal: Terminal) -> [SignalLightColor]? {
        let palette: [SignalLightColor] = [.red, .yellow, .green]
        let labels = palette.map(ConfigFormat.colorName)
        let preselected = Set(current.colors.compactMap { palette.firstIndex(of: $0) })

        while true {
            let chosen = MultiSelect.choose(
                items: labels,
                preselected: preselected,
                terminal: terminal,
                trail: ["灯效设置", bucketName],
                context: {
                    ["第 2 步：哪些颜色"]
                },
                footerHint: terminal.keyBar([.move, .spaceToggle, .enter("确认"), .escape("返回")])
            )
            guard let chosen else { return nil }
            if chosen.isEmpty {
                terminal.warn("至少要选一个颜色。")
                MenuPrompt.pause(terminal, message: "回车 重选")
                continue
            }
            return palette.enumerated().compactMap { chosen.contains($0.offset) ? $0.element : nil }
        }
    }

    /// Offers to push the just-edited effect straight to the physical device
    /// before it's saved — otherwise saving a bucket that isn't the one
    /// currently active gives zero visible feedback that anything happened
    /// (e.g. editing "运行中" while the light is sitting idle). Skipped
    /// silently when no device is paired: there's nothing to preview.
    private static func previewIfWanted(_ effect: SignalLightEffect, paths: SignalLightDaemonPaths, terminal: Terminal) async {
        guard let device = try? SignalLightDeviceStore.load(from: paths.deviceJSONURL),
              let deviceID = UUID(uuidString: device.identifier) else {
            return
        }
        guard Confirm.promptYesNo(terminal, "先试试这个效果？", defaultAnswer: false) else { return }

        let control = LaunchAgentControl(paths: paths)
        do {
            try await DaemonPause.run(terminal: terminal, control: control) {
                let session = SignalLightBLESession(pairedDeviceID: deviceID)
                terminal.progress("\(terminal.emoji(CLIGlyph.search))正在连接信号灯预览…")
                try await session.connect()
                defer { session.disconnect() }

                try await session.sendCommand(SignalLightCommandEncoder.encode(effect))
                terminal.out("已发到灯上。")
                MenuPrompt.pause(terminal, message: "回车 结束预览")
                try? await session.sendCommand(SignalLightControlCommand.off)
            }
        } catch let cliError as CLIError {
            terminal.errorLine(cliError.message)
        } catch {
            terminal.errorLine("预览失败：\(error)")
        }
    }

    private static func editBrightness(current: Int, terminal: Terminal) async {
        guard let value = MenuPrompt.integer("全局亮度（0-100）", default: current) else { return }
        await MenuCommandRunner.run(["config", "brightness", String(value)], terminal: terminal)
        MenuPrompt.pause(terminal)
    }

    private static func confirmReset(terminal: Terminal) async {
        guard Confirm.promptYesNo(terminal, "所有灯效恢复默认？", defaultAnswer: false) else {
            CLIRuntimeContext.markCommandCancelled(.silentCancel)
            return
        }
        await MenuCommandRunner.run(["config", "reset"], terminal: terminal)
    }
}
