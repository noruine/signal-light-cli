import Foundation
import Testing

import SignalLightKit
@testable import SignalLightCLICore

/// Every screen's fixed chrome is plain text, so it is tested as text: the
/// one vocabulary, the one separator, one spacing (the `ScreenLayout` every
/// screen renders through), and the frames the painters compose.
@Suite("Menu chrome")
struct MenuChromeTests {
    private let plain = Terminal(colorMode: .never, environment: [:])
    private let decorated = Terminal(colorMode: .always, isOutputTTY: true, environment: [:])

    @Test("Key hints keep the one vocabulary")
    func keyHintWording() {
        #expect(KeyHint.move.text == "↑/↓ 移动")
        #expect(KeyHint.spaceToggle.text == "Space 勾选")
        #expect(KeyHint.enter("确认").text == "Enter 确认")
        #expect(KeyHint.enter("继续").text == "Enter 继续")
        #expect(KeyHint.escape("返回").text == "Esc 返回")
        #expect(KeyHint.escape("退出").text == "Esc 退出")
        #expect(KeyHint.escape("取消").text == "Esc 取消")
    }

    @Test("The key bar joins with the one separator in the fixed order")
    func keyBarComposition() {
        #expect(plain.keyBar([.move, .enter("确认"), .escape("返回")]) == "↑/↓ 移动 · Enter 确认 · Esc 返回")
        #expect(plain.keyBar([.enter("继续")]) == "Enter 继续")
        #expect(plain.keyBar([.move, .spaceToggle, .enter("确认"), .escape("返回")])
            == "↑/↓ 移动 · Space 勾选 · Enter 确认 · Esc 返回")
    }

    @Test("Line editor backspace removes one Unicode character")
    func lineBufferBackspace() {
        var buffer = MenuLineBuffer()
        for byte in "灯名".utf8 {
            buffer.append(byte)
        }

        #expect(buffer.deleteLastCharacter() == 2)
        #expect(buffer.value == "灯")

        for byte in "👩‍💻".utf8 {
            buffer.append(byte)
        }
        #expect(buffer.deleteLastCharacter() == 2)
        #expect(buffer.value == "灯")
        for byte in "🇨🇳👍🏽".utf8 {
            buffer.append(byte)
        }
        #expect(buffer.deleteLastCharacter() == 2)
        #expect(buffer.value == "灯🇨🇳")
        #expect(buffer.deleteLastCharacter() == 2)
        #expect(buffer.value == "灯")
        #expect(buffer.deleteLastCharacter() == 2)
        #expect(buffer.value.isEmpty)
        #expect(buffer.deleteLastCharacter() == 0)
    }

    @Test("A new step starts on a clean screen")
    func beginStepClearsTheFrame() {
        var emitted: [String] = []
        ScreenLayout.beginStep(emit: { emitted.append($0) })
        #expect(emitted == ["\u{1B}[2J\u{1B}[H"])
    }

    @Test("Command pages keep the menu frame during progress")
    func menuCommandFrame() {
        let lines = MenuActionScreen.lines(
            terminal: plain,
            trail: ["设备管理", "固件更新"],
            body: ["正在连接信号灯…"],
            footer: "Esc 取消"
        )

        #expect(lines == [
            "信号灯 › 设备管理 › 固件更新",
            "",
            "正在连接信号灯…",
            "",
            "Esc 取消",
        ])
    }

    @Test("The header's hooks segment names the hooked agents, or 未接入")
    func hooksSegmentWording() {
        #expect(StatusSnapshot.menuHooksDescription(for: []) == "未接入")
        #expect(StatusSnapshot.menuHooksDescription(for: ["Codex"]) == "Codex")
        #expect(StatusSnapshot.menuHooksDescription(for: ["Claude Code", "Codex"]) == "Claude Code + Codex")
    }

    @Test("The interactive header omits session counts")
    func menuHeaderOmitsSessionCounts() {
        let sessions = [
            SessionRegistry.SessionStatus(source: .codex, sessionID: "working", phase: .running),
            SessionRegistry.SessionStatus(source: .codex, sessionID: "other", phase: .idle),
        ]
        let snapshot = StatusSnapshot(
            paths: SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp")),
            jobInfo: LaunchAgentControl.JobInfo(isLoaded: true, pid: 1),
            runAtLoad: true,
            toolInstalled: true,
            state: SignalLightDaemonState(
                ble: .connected,
                deviceName: "blinkenlights",
                currentBucket: "running",
                sessions: sessions,
                updatedAt: .now,
                pid: 1
            ),
            stateIsLive: true,
            pairedDeviceName: "blinkenlights",
            deviceName: "blinkenlights",
            hookedAgents: ["Codex"]
        )

        #expect(snapshot.menuHeaderLines(terminal: plain) == [
            "    服务      [on] 运行中 · 自启开",
            "    Hooks     [on] Codex",
            "    蓝牙      [on] blinkenlights",
            "    当前状态  🏃工作中",
        ])
        #expect(!snapshot.menuHeaderLines(terminal: plain).joined().contains("灯态主导"))
        #expect(!snapshot.humanReadableLines(terminal: plain, includeHeading: false)
            .joined().contains("会话"))
    }

    @Test("A status snapshot is live only when launchd owns its PID")
    func statusSnapshotChecksLaunchAgentPID() {
        let state = SignalLightDaemonState(
            ble: .connected,
            deviceName: "blinkenlights",
            currentBucket: "running",
            sessions: [],
            updatedAt: .now,
            pid: 42
        )

        #expect(StatusSnapshot.isStateLive(
            state,
            jobInfo: LaunchAgentControl.JobInfo(isLoaded: true, pid: 42),
            processIsAlive: { _ in true }
        ))
        #expect(!StatusSnapshot.isStateLive(
            state,
            jobInfo: LaunchAgentControl.JobInfo(isLoaded: true, pid: 99),
            processIsAlive: { _ in true }
        ))
        #expect(!StatusSnapshot.isStateLive(
            state,
            jobInfo: LaunchAgentControl.JobInfo(isLoaded: false, pid: 42),
            processIsAlive: { _ in true }
        ))
    }

    @Test("Interactive refresh reloads daemon state without replacing menu metadata")
    func refreshRuntimeState() throws {
        let home = URL(fileURLWithPath: "/tmp/sl-status-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = SignalLightDaemonPaths(home: home)
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let initialState = SignalLightDaemonState(
            ble: .connected,
            deviceName: "blinkenlights",
            currentBucket: "idle",
            sessions: [],
            updatedAt: .now,
            pid: pid
        )
        let updatedState = SignalLightDaemonState(
            ble: .connected,
            deviceName: "blinkenlights",
            currentBucket: "running",
            sessions: [
                SessionRegistry.SessionStatus(source: .codex, sessionID: "working", phase: .running),
            ],
            updatedAt: .now,
            pid: pid
        )
        try SignalLightDaemonStateStore.save(updatedState, to: paths.stateJSONURL)
        let snapshot = StatusSnapshot(
            paths: paths,
            jobInfo: LaunchAgentControl.JobInfo(isLoaded: true, pid: pid),
            runAtLoad: true,
            toolInstalled: true,
            state: initialState,
            stateIsLive: true,
            pairedDeviceName: "blinkenlights",
            deviceName: "blinkenlights",
            hookedAgents: ["Codex"]
        )

        let refreshed = snapshot.refreshingRuntimeState()

        #expect(refreshed.state?.currentBucket == "running")
        #expect(refreshed.state?.sessions?.count == 1)
        #expect(refreshed.hookedAgents == ["Codex"])
        #expect(refreshed.runAtLoad == true)
    }

    @Test("A stale daemon snapshot does not expose its update timestamp")
    func staleStatusOmitsStateTimestamp() {
        let state = SignalLightDaemonState(
            ble: .connected,
            deviceName: "blinkenlights",
            currentBucket: "running",
            sessions: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 42
        )
        let snapshot = StatusSnapshot(
            paths: SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp")),
            jobInfo: LaunchAgentControl.JobInfo(isLoaded: false, pid: nil),
            runAtLoad: nil,
            toolInstalled: true,
            state: state,
            stateIsLive: false,
            pairedDeviceName: "blinkenlights",
            deviceName: "blinkenlights",
            hookedAgents: []
        )

        #expect(snapshot.liveStateUpdatedAt == nil)
    }

    @Test("The menu brackets rendering with screen and wheel modes")
    func menuScreenBufferLifecycle() async {
        var events: [String] = []

        let result = await MenuScreenBuffer.withAlternateBuffer(emit: { events.append($0) }) {
            events.append("menu")
            return "done"
        }

        #expect(result == "done")
        #expect(events == ["\u{1B}[?1049h\u{1B}[?1007l", "menu", "\u{1B}[?1049l"])
    }

    @Test("The breadcrumb reads root, then the trail")
    func breadcrumbTrail() {
        #expect(plain.menuBreadcrumb() == "信号灯")
        #expect(plain.menuBreadcrumb(["诊断"]) == "信号灯 › 诊断")
        #expect(plain.menuBreadcrumb(["诊断", "查看文件清单"]) == "信号灯 › 诊断 › 查看文件清单")
        #expect(plain.menuBreadcrumb(["灯效设置", "空闲"]) == "信号灯 › 灯效设置 › 空闲")
        #expect(plain.menuBreadcrumb(["设备管理", "重新扫描并配对"]) == "信号灯 › 设备管理 › 重新扫描并配对")
    }

    @Test("The decorated breadcrumb leads with the light glyph")
    func breadcrumbDecoration() {
        let crumb = decorated.menuBreadcrumb(["诊断"])
        #expect(crumb.hasPrefix("🚦  "))
        #expect(crumb.contains("诊断"))
    }

    @Test("The layout keeps one spacing: breadcrumb, blank, context, blank, body, blank, bar")
    func layoutSpacing() {
        let lines = ScreenLayout.lines(
            terminal: plain,
            trail: ["诊断"],
            context: ["版本 9.9.9"],
            body: ["1. 体检"],
            bar: plain.keyBar([.move, .enter("确认"), .escape("返回")])
        )
        #expect(lines == [
            "信号灯 › 诊断",
            "",
            "版本 9.9.9",
            "",
            "1. 体检",
            "",
            "↑/↓ 移动 · Enter 确认 · Esc 返回",
        ])
    }

    @Test("A result screen has no info block: breadcrumb, blank, output, blank, bar")
    func layoutResultScreen() {
        let lines = ScreenLayout.lines(
            terminal: plain,
            trail: ["诊断", "查看文件清单"],
            context: [],
            body: ["● 存在"],
            bar: plain.keyBar([.enter("继续")])
        )
        #expect(lines == ["信号灯 › 诊断 › 查看文件清单", "", "● 存在", "", "Enter 继续"])
    }

    @Test("A screen continuing another has no breadcrumb of its own")
    func layoutWithoutBreadcrumb() {
        let lines = ScreenLayout.lines(
            terminal: plain,
            trail: nil,
            context: [],
            body: ["继续？  [否]"],
            bar: plain.keyBar([.enter("确认"), .escape("取消")])
        )
        #expect(lines == ["继续？  [否]", "", "Enter 确认 · Esc 取消"])
    }

    @Test("A bare CLI picker keeps its info without the menu breadcrumb")
    func layoutWithoutBreadcrumbWithContext() {
        let lines = ScreenLayout.lines(
            terminal: plain,
            trail: nil,
            context: ["找到 2 个设备，选择要配对的："],
            body: ["1. 灯 A"],
            bar: plain.keyBar([.move, .enter("确认"), .escape("取消")])
        )
        #expect(lines == ["找到 2 个设备，选择要配对的：", "", "1. 灯 A", "", "↑/↓ 移动 · Enter 确认 · Esc 取消"])
    }

    @Test("The confirm frame is question, blank line, key bar")
    func confirmFrameLayout() {
        let lines = Confirm.frame(plain, question: "继续？", yes: false)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("继续？"))
        #expect(lines[0].contains("是"))
        #expect(lines[0].contains("[否]"))
        #expect(lines[1].isEmpty)
        #expect(lines[2] == "↑/↓ 移动 · Enter 确认 · Esc 取消")
    }

    @Test("A confirmation can highlight yes by default")
    func confirmFrameDefaultsToYes() {
        let lines = Confirm.frame(plain, question: "升级？", yes: true)
        #expect(lines[0].contains("[是]"))
        #expect(lines[0].contains("否"))
    }

    @Test("A picker frame reads breadcrumb, context, body, then the bar")
    func pickerFrameLayout() {
        var out: [String] = []
        MenuSelector.render(
            items: ["常亮  solid", "呼吸  breathe"],
            selected: 1,
            terminal: plain,
            trail: ["灯效设置", "空闲"],
            context: { ["第 1 步：怎么亮"] },
            footerHint: plain.keyBar([.move, .enter("确认"), .escape("取消")]),
            emit: { out.append($0) }
        )
        let text = out.joined()
        #expect(text.contains("信号灯 › 灯效设置 › 空闲"))
        #expect(text.contains("1. 常亮  solid"))
        #expect(text.contains("↑/↓ 移动 · Enter 确认 · Esc 取消"))
        if let crumb = text.range(of: "信号灯 › 灯效设置 › 空闲"),
           let context = text.range(of: "第 1 步：怎么亮"),
           let firstItem = text.range(of: "1. 常亮"),
           let bar = text.range(of: "↑/↓ 移动") {
            #expect(crumb.lowerBound < context.lowerBound)
            #expect(context.lowerBound < firstItem.lowerBound)
            #expect(firstItem.lowerBound < bar.lowerBound)
        } else {
            Issue.record("frame pieces are missing from the picker render")
        }
    }

    @Test("A checkbox frame reads breadcrumb, body, then the bar")
    func multiSelectFrameLayout() {
        var out: [String] = []
        MultiSelect.render(
            items: ["Claude Code", "Codex"],
            checked: [],
            cursor: 0,
            terminal: plain,
            trail: ["接入 Agent"],
            context: { [] },
            footerHint: plain.keyBar([.move, .spaceToggle, .enter("确认"), .escape("返回")]),
            emit: { out.append($0) }
        )
        let text = out.joined()
        #expect(text.contains("信号灯 › 接入 Agent"))
        #expect(text.contains("[ ] Claude Code"))
        #expect(text.contains("↑/↓ 移动 · Space 勾选 · Enter 确认 · Esc 返回"))
    }

    @Test("Menu endings tell silent and announced cancels apart")
    func commandEndings() {
        #expect(CLIRuntimeContext.consumeCommandEnding() == .completed)
        CLIRuntimeContext.markCommandCancelled(.silentCancel)
        #expect(CLIRuntimeContext.consumeCommandEnding() == .silentCancel)
        CLIRuntimeContext.markCommandCancelled()
        #expect(CLIRuntimeContext.consumeCommandEnding() == .announcedCancel)
        #expect(CLIRuntimeContext.consumeCommandEnding() == .completed)
    }
}
