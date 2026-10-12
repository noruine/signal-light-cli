import ArgumentParser
import Foundation
import SignalLightKit

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "接线校准：逐个点亮 GPIO，记录红/黄/绿各接在哪个引脚，然后写进设备。"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        // Calibration is inherently interactive — the user reads the physical
        // light and types what they see, so there's no meaningful headless mode.
        guard terminal.isInteractive else {
            throw CLIError("校准只能在真实终端里进行，当前环境不行。", exitCode: .usage)
        }

        guard let device = try SignalLightStores.loadPairedDevice(from: paths.deviceJSONURL),
              let deviceID = UUID(uuidString: device.identifier) else {
            throw CLIError("还没配对，请先运行 signal-light pair。", exitCode: .noInput)
        }

        let control = LaunchAgentControl(paths: paths)
        try await DaemonPause.run(terminal: terminal, control: control) {
            try await runCalibration(terminal: terminal, deviceID: deviceID)
        }
    }

    private func runCalibration(terminal: Terminal, deviceID: UUID) async throws {
        let session = SignalLightBLESession(pairedDeviceID: deviceID)
        terminal.progress("\(terminal.emoji(CLIGlyph.search))正在连灯…")
        try await session.connect()
        defer { session.disconnect() }

        // Silence any running effect so it can't be confused with a pin test.
        try await session.sendCommand(SignalLightControlCommand.off)

        if let config = try? await session.getConfig() {
            terminal.out("当前引脚映射：红=\(config.pins[.red].map(String.init) ?? "?") 黄=\(config.pins[.yellow].map(String.init) ?? "?") 绿=\(config.pins[.green].map(String.init) ?? "?")")
        }

        terminal.out("")
        terminal.out("会逐个点亮引脚，你看灯、报颜色就行。")
        guard Confirm.promptYesNo(terminal, "开始接线校准？", defaultAnswer: true) else {
            CancelNotice.say("已取消。", terminal: terminal)
            return
        }

        var wizard = SignalLightCalibrationWizard(candidatePins: SignalLightCalibrationWizard.defaultCandidatePins)

        while let pin = wizard.currentPin {
            let remaining = wizard.unresolvedColors.map(ConfigFormat.colorName).joined(separator: "、")
            terminal.out("")
            terminal.out("GPIO \(pin)（还差：\(remaining)）")
            try await session.sendCommand(SignalLightControlCommand.pinTest(pin: pin, on: true))
            terminal.progress("GPIO \(pin) 已通电，看灯。")

            let observation = promptObservation()
            try await session.sendCommand(SignalLightControlCommand.pinTest(pin: pin, on: false))

            guard let observation else {
                CancelNotice.say("已取消校准。", terminal: terminal)
                return
            }

            let mappingBefore = wizard.mapping
            wizard.recordObservation(observation)

            // Confirm based on what the wizard actually recorded, not on what
            // the user typed: it ignores a color that's already assigned, and
            // printing "记录：红 = GPIO X" in that case would be a lie.
            if let color = reportedColor(observation) {
                if wizard.mapping[color] == pin, mappingBefore[color] == nil {
                    terminal.out("\(terminal.emoji(CLIGlyph.success))记录：\(ConfigFormat.colorName(color)) = GPIO \(pin)")
                } else {
                    terminal.warn("\(ConfigFormat.colorName(color)) 已经记过，这次跳过。")
                }
            } else {
                terminal.out("未记录。")
            }
        }

        try await saveMappingIfComplete(wizard, session: session, terminal: terminal)
        try await session.sendCommand(SignalLightControlCommand.off)
    }

    private func saveMappingIfComplete(
        _ wizard: SignalLightCalibrationWizard,
        session: SignalLightBLESession,
        terminal: Terminal
    ) async throws {
        guard let red = wizard.mapping[.red],
              let yellow = wizard.mapping[.yellow],
              let green = wizard.mapping[.green] else {
            terminal.out("")
            terminal.warn("三色没有配齐，未保存。想重来：signal-light calibrate")
            return
        }

        terminal.out("")
        terminal.out("校准结果：红=GPIO \(red)  黄=GPIO \(yellow)  绿=GPIO \(green)")
        guard Confirm.promptYesNo(terminal, "写进设备，以后一直用这套？", defaultAnswer: true) else {
            terminal.out("未保存。")
            return
        }

        try await session.sendCommand(SignalLightControlCommand.setPin(color: .red, pin: red))
        try await session.sendCommand(SignalLightControlCommand.setPin(color: .yellow, pin: yellow))
        try await session.sendCommand(SignalLightControlCommand.setPin(color: .green, pin: green))
        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("已保存，引脚配置写进设备。"))")
    }

    /// Single-key observation prompt: the answer is one letter and this step
    /// repeats for every candidate pin, so requiring a following Enter would
    /// just add noise. Enter / Space / n mean "nothing lit"; Esc (or Ctrl-C)
    /// cancels the whole calibration and records nothing.
    private func promptObservation() -> SignalLightWizardObservation? {
        FileHandle.standardError.write(Data("看到什么颜色？按 r 红 / y 黄 / g 绿 / n 没亮，Esc 取消：".utf8))

        guard let original = RawMode.enter() else {
            let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            FileHandle.standardError.write(Data("\n".utf8))
            switch line {
            case "r": return .red
            case "y": return .yellow
            case "g": return .green
            default: return .nothing
            }
        }
        defer {
            RawMode.restore(original)
            FileHandle.standardError.write(Data("\n".utf8))
        }

        while true {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }

            switch byte {
            case 0x0A, 0x0D, 0x20:  // Enter / Space
                return .nothing
            case 0x72, 0x52:  // r / R
                return .red
            case 0x79, 0x59:  // y / Y
                return .yellow
            case 0x67, 0x47:  // g / G
                return .green
            case 0x6E, 0x4E:  // n / N
                return .nothing
            case 0x03, 0x04:  // Ctrl-C / Ctrl-D
                return nil
            case 0x1B:  // Esc, or an arrow-key sequence
                if case .lone = RawMode.classifyEscape() { return nil }
                // Arrow/other sequence: ignore.
            default:
                continue  // unknown key: wait for a valid one
            }
        }
    }

    private func reportedColor(_ observation: SignalLightWizardObservation) -> SignalLightColor? {
        switch observation {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .nothing: nil
        }
    }
}
