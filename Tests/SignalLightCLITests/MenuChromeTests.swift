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
        #expect(KeyHint.spaceToggle.text == "空格 勾选")
        #expect(KeyHint.enter("确认").text == "回车 确认")
        #expect(KeyHint.enter("继续").text == "回车 继续")
        #expect(KeyHint.escape("返回").text == "Esc 返回")
        #expect(KeyHint.escape("退出").text == "Esc 退出")
        #expect(KeyHint.escape("取消").text == "Esc 取消")
    }

    @Test("The key bar joins with the one separator in the fixed order")
    func keyBarComposition() {
        #expect(plain.keyBar([.move, .enter("确认"), .escape("返回")]) == "↑/↓ 移动 · 回车 确认 · Esc 返回")
        #expect(plain.keyBar([.enter("继续")]) == "回车 继续")
        #expect(plain.keyBar([.move, .spaceToggle, .enter("确认"), .escape("返回")])
            == "↑/↓ 移动 · 空格 勾选 · 回车 确认 · Esc 返回")
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
            "↑/↓ 移动 · 回车 确认 · Esc 返回",
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
        #expect(lines == ["信号灯 › 诊断 › 查看文件清单", "", "● 存在", "", "回车 继续"])
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
        #expect(lines == ["继续？  [否]", "", "回车 确认 · Esc 取消"])
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
        #expect(lines == ["找到 2 个设备，选择要配对的：", "", "1. 灯 A", "", "↑/↓ 移动 · 回车 确认 · Esc 取消"])
    }

    @Test("The confirm frame is question, blank line, key bar")
    func confirmFrameLayout() {
        let lines = Confirm.frame(plain, question: "继续？", yes: false)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("继续？"))
        #expect(lines[0].contains("是"))
        #expect(lines[0].contains("[否]"))
        #expect(lines[1].isEmpty)
        #expect(lines[2] == "↑/↓ 移动 · 回车 确认 · Esc 取消")
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
        #expect(text.contains("↑/↓ 移动 · 回车 确认 · Esc 取消"))
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
        #expect(text.contains("↑/↓ 移动 · 空格 勾选 · 回车 确认 · Esc 返回"))
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
