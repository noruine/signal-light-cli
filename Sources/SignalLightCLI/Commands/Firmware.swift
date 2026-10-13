import ArgumentParser
import Foundation
import SignalLightKit

struct Firmware: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "固件：检查新版本或通过蓝牙无线升级（OTA）。",
        subcommands: [Check.self, Update.self]
    )

    // MARK: check

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "检查是否有新固件版本。")

        @OptionGroup var globals: GlobalOptions

        @Option(help: "跳过读取设备、直接用指定的当前版本号比较（按 esp32c3 的固件清单，避免临时断开后台服务）。")
        var current: String?

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()
            let availability = try await FirmwareSupport.checkAvailability(explicitVersion: current, terminal: terminal, paths: paths)
            FirmwareSupport.printCheckResult(availability, terminal: terminal)
            if case .updateAvailable = availability {
                terminal.out("    升级：signal-light firmware update")
            }
        }
    }

    // MARK: update

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "update", abstract: "通过蓝牙 OTA 升级固件。")

        @OptionGroup var globals: GlobalOptions

        @Option(help: "指定本地 .bin 固件文件；省略则自动下载最新版本。")
        var file: String?

        @Flag(name: [.customShort("y"), .long], help: "跳过确认提示（非交互环境下必须传入）。")
        var yes: Bool = false

        func run() async throws {
            let terminal = globals.makeTerminal()
            let paths = SignalLightDaemonPaths.current()

            guard let device = try SignalLightStores.loadPairedDevice(from: paths.deviceJSONURL),
                  let deviceID = UUID(uuidString: device.identifier) else {
                throw CLIError(ContextText.choose(cli: "还没配对，请运行 signal-light pair。", menu: "还没配对。"), exitCode: .noInput)
            }

            // Checked before anything is paused or connected: a script that
            // forgot --yes should not disturb the running service first.
            guard yes || terminal.isInteractive else {
                throw CLIError("非交互升级要加 --yes。", exitCode: .usage)
            }

            let control = LaunchAgentControl(paths: paths)
            try await DaemonPause.run(terminal: terminal, control: control) {
                try await runUpdate(terminal: terminal, deviceID: deviceID)
            }
        }

        /// The one line of safety copy before flashing — deliberately not a
        /// block of bullets: this runs right after the "有新版本" line and a
        /// wall of text there reads as noise. Returns false when the user
        /// answers no; nothing has been touched at that point, so the caller
        /// just stops and says so — a cancel is not an error.
        private func confirmProceed(terminal: Terminal) -> Bool {
            guard !yes else { return true }
            return Confirm.promptYesNo(
                terminal,
                "升级时别断电、别关程序；电脑和灯离近点（约 1–2 分钟）。开始？",
                defaultAnswer: false
            )
        }

        private func runUpdate(terminal: Terminal, deviceID: UUID) async throws {
            let session = SignalLightBLESession(pairedDeviceID: deviceID)
            terminal.progress("\(terminal.emoji(CLIGlyph.search))正在连接信号灯…")
            try await session.connect()
            defer { session.disconnect() }

            guard session.hasOTACharacteristics else {
                throw CLIError("这盏灯不支持 OTA（缺少升级用的蓝牙特征）。", exitCode: .unavailable)
            }

            let firmware = try await resolveFirmwareFile(session: session, terminal: terminal)
            guard let firmware else {
                // Nothing to flash: either already latest (the version line
                // above is the whole answer) or the user cancelled, which was
                // said out loud already.
                return
            }
            // A firmware binary we downloaded is one-shot scratch; never leave
            // it behind (a user-supplied --file is theirs to keep).
            defer {
                if firmware.isDownloaded {
                    try? FileManager.default.removeItem(at: firmware.url)
                }
            }
            guard let data = try? Data(contentsOf: firmware.url), !data.isEmpty else {
                throw CLIError("读取固件文件失败：\(firmware.url.path)", exitCode: .noInput)
            }
            terminal.out("固件大小：\(data.count) 字节")

            try await transfer(data: data, session: session, terminal: terminal)
        }

        /// Finds the binary to flash: the one the user pointed at, or — after
        /// comparing versions over BLE — the latest published for this board.
        /// `nil` means "already up to date, nothing to flash", which is a
        /// normal outcome for `firmware update`, not an error.
        private func resolveFirmwareFile(
            session: SignalLightBLESession,
            terminal: Terminal
        ) async throws -> (url: URL, isDownloaded: Bool)? {
            if let file {
                // The explicit path used to skip the warning entirely, so the
                // one flashing route with no version check was also the one
                // with no "don't unplug it" line.
                guard confirmProceed(terminal: terminal) else {
                    CancelNotice.say("已取消。", terminal: terminal)
                    return nil
                }
                return (URL(fileURLWithPath: (file as NSString).expandingTildeInPath), isDownloaded: false)
            }

            let info = SignalLightDeviceInfo.parse(try await session.readInfo())
            let availability = try await FirmwareUpdateChecker().check(
                hardware: info.hardware,
                currentVersion: info.version
            )
            FirmwareSupport.printCheckResult(availability, terminal: terminal)
            guard case .updateAvailable = availability else {
                return nil
            }

            guard confirmProceed(terminal: terminal) else {
                CancelNotice.say("已取消。", terminal: terminal)
                return nil
            }
            terminal.progress("正在下载固件（\(info.hardware)，最长约 1 分钟，按 Ctrl-C 取消）…")
            do {
                let downloaded = try await runWhileListeningForCancel(terminal: terminal) {
                    try await FirmwareUpdateChecker().downloadLatest(hardware: info.hardware)
                }
                return (downloaded.url, isDownloaded: true)
            } catch UserCancellation.cancelled {
                CancelNotice.say("已取消下载。", terminal: terminal)
                return nil
            }
        }

        private func transfer(data: Data, session: SignalLightBLESession, terminal: Terminal) async throws {
            do {
                // Sending the image is cancellable: the firmware discards the
                // staged image on OTA_ABORT and keeps running what it has.
                try await runWhileListeningForCancel(terminal: terminal) {
                    terminal.progress("正在启动升级会话…")
                    try await session.sendControl("OTA_BEGIN:\(data.count)")
                    let begin = try await session.awaitNotification(prefix: "OTA_BEGIN", timeout: 10)
                    guard begin.uppercased().contains("OK") else {
                        throw SignalLightSessionError.firmwareRejected(begin)
                    }

                    let chunkSize = session.maxWriteChunkSize
                    var offset = 0
                    while offset < data.count {
                        // Ctrl-C lands here, between chunks.
                        try Task.checkCancellation()
                        let end = min(offset + chunkSize, data.count)
                        try await session.sendData(data.subdata(in: offset..<end))
                        offset = end
                        Self.renderProgress(sent: offset, total: data.count, terminal: terminal)
                    }
                    Self.finishProgressLine(terminal: terminal)
                }

                // Committing is not cancellable: the device already has the
                // image and is verifying it, so Ctrl-C only gets a note.
                try await runWhileAnsweringInterruptKeys(
                    terminal: terminal,
                    note: "正在提交，不能中断；马上完成。"
                ) {
                    terminal.progress("正在校验并提交…")
                    try await session.sendControl("OTA_END")
                    let endResp = try await session.awaitNotification(prefix: "OTA_END", timeout: 20)
                    let ok = endResp.uppercased().contains("OK") || endResp.lowercased().contains("restart")
                    guard ok else {
                        throw SignalLightSessionError.firmwareRejected(endResp)
                    }
                }

                terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("固件已升级，设备将自动重启生效。"))")
            } catch UserCancellation.cancelled {
                try? await session.sendControl("OTA_ABORT")
                CancelNotice.say("已取消升级。", terminal: terminal)
            } catch {
                // Best effort: tell the firmware to abandon the half-written
                // image so a failed attempt doesn't leave it in a bad state.
                try? await session.sendControl("OTA_ABORT")
                throw CLIError("升级失败：\(error)。原固件未受影响。", exitCode: .software)
            }
        }

        /// A single rewritten `\r` line on stderr (never stdout — stdout
        /// stays clean for any captured result). Only drawn on an interactive
        /// terminal: a redirected/piped stderr can't handle carriage returns,
        /// so there it would just accumulate hundreds of junk lines.
        ///
        /// Static so the transfer's `@Sendable` closures can call it without
        /// capturing the command instance.
        private static func renderProgress(sent: Int, total: Int, terminal: Terminal) {
            guard terminal.isInteractive, !terminal.quiet else { return }
            let percent = total > 0 ? Int(100 * Double(sent) / Double(total)) : 100
            let barWidth = 24
            let filled = total > 0 ? Int(Double(barWidth) * Double(sent) / Double(total)) : barWidth
            let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: barWidth - filled)
            FileHandle.standardError.write(Data("\r进度 [\(bar)] \(percent)% (\(sent)/\(total))".utf8))
        }

        private static func finishProgressLine(terminal: Terminal) {
            guard terminal.isInteractive, !terminal.quiet else { return }
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}

/// Reads the connected device's hardware id + firmware version over BLE, or
/// uses an explicitly supplied version to avoid disturbing the daemon. Shared
/// by `firmware check` and the menu's "固件更新" item, so checking for an
/// update isn't implemented twice — the menu only adds the "found one, want
/// to install it now?" prompt on top.
enum FirmwareSupport {
    static func checkAvailability(
        explicitVersion: String?,
        terminal: Terminal,
        paths: SignalLightDaemonPaths
    ) async throws -> FirmwareUpdateAvailability {
        let info = try await resolveDeviceInfo(explicitVersion: explicitVersion, terminal: terminal, paths: paths)
        if explicitVersion != nil {
            // `--current` skips the device read, so the board can't be known:
            // the manifest below is always the legacy board's. Say which one
            // was compared, or a non-esp32c3 user would read a verdict about
            // somebody else's hardware.
            terminal.progress("跳过读设备，按 \(SignalLightDeviceInfo.legacyHardware) 的固件清单检查…")
        }
        terminal.progress("正在检查更新…")
        return try await FirmwareUpdateChecker().check(hardware: info.hardware, currentVersion: info.version)
    }

    static func printCheckResult(_ availability: FirmwareUpdateAvailability, terminal: Terminal) {
        switch availability {
        case let .upToDate(current):
            terminal.out("\(terminal.emoji(CLIGlyph.success))已是最新版本（\(current)）。")
        case let .updateAvailable(current, latest, notes):
            terminal.out("\(terminal.emoji(CLIGlyph.package))\(terminal.warning("有新版本可用"))：\(current) → \(latest)")
            if let notes, !notes.isEmpty {
                terminal.out("    更新说明：\(notes)")
            }
        }
    }

    private static func resolveDeviceInfo(
        explicitVersion: String?,
        terminal: Terminal,
        paths: SignalLightDaemonPaths
    ) async throws -> SignalLightDeviceInfo {
        if let explicitVersion {
            return SignalLightDeviceInfo(hardware: SignalLightDeviceInfo.legacyHardware, version: explicitVersion)
        }

        guard let device = try SignalLightStores.loadPairedDevice(from: paths.deviceJSONURL),
              let deviceID = UUID(uuidString: device.identifier) else {
            throw CLIError("还没配对，读不到灯上的固件版本；先配对，或自行指定版本号：--current x.y.z。", exitCode: .noInput)
        }

        let control = LaunchAgentControl(paths: paths)
        return try await DaemonPause.run(terminal: terminal, control: control) {
            let session = SignalLightBLESession(pairedDeviceID: deviceID)
            terminal.progress("\(terminal.emoji(CLIGlyph.search))正在读取固件版本…")
            try await session.connect()
            defer { session.disconnect() }
            return SignalLightDeviceInfo.parse(try await session.readInfo())
        }
    }
}

/// Thrown when the user presses Ctrl-C through one of the firmware waits; the
/// caller decides what stopping means (abandon the download, or abort the OTA
/// session).
private enum UserCancellation: Error {
    case cancelled
}

/// Runs `body` while watching for Ctrl-C, so a network wait can be abandoned
/// from the terminal itself.
///
/// The key is read rather than left to the terminal's SIGINT: inside terminal
/// wrappers the signal sometimes never reaches the process, and a signal kill
/// would also skip the daemon restore this command owes the user. `body` has
/// to notice cancellation itself (`Task.checkCancellation()` in its loop) —
/// that is how the stop reaches it.
private func runWhileListeningForCancel<T: Sendable>(
    terminal: Terminal,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard terminal.isInteractive else {
        return try await body()
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await waitForCancelKey()
            throw UserCancellation.cancelled
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        return first
    }
}

/// Runs `body` while reading interrupt keys and answering each one with
/// `note` instead of stopping. Used while the firmware commits: there is
/// nothing safe left to cancel, and keys left to the terminal would either
/// echo `^[` junk into the progress line or, as a real SIGINT, kill the
/// process before the daemon is put back.
private func runWhileAnsweringInterruptKeys<T: Sendable>(
    terminal: Terminal,
    note: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard terminal.isInteractive else {
        return try await body()
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            guard let original = RawMode.enter(interceptingInterrupts: true) else {
                while true {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                }
            }
            defer { RawMode.restore(original) }

            // A held key repeats; one line per few seconds is enough to show
            // the press registered.
            var lastNoteAt: ContinuousClock.Instant?
            while true {
                _ = try await waitForInterruptKey()
                let now = ContinuousClock.now
                if let lastNoteAt, now - lastNoteAt < .seconds(3) {
                    continue
                }
                lastNoteAt = now
                FileHandle.standardError.write(Data("\r\(note)\n".utf8))
            }
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        return first
    }
}

/// Returns only to mean "the user pressed Ctrl-C". Ctrl-C is the terminal's
/// own interrupt, the one key a stuck program is expected to answer — the
/// waits advertise it rather than an Esc shortcut that competes with menu
/// muscle memory. A non-TTY, EOF or a cancelled task never counts as a stop:
/// `body` stays the only other way out.
private func waitForCancelKey() async throws {
    guard let original = RawMode.enter(interceptingInterrupts: true) else {
        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
    defer { RawMode.restore(original) }

    while true {
        if try await waitForInterruptKey() == .ctrlC {
            return
        }
    }
}

/// What the just-read interrupt key was. Only Ctrl-C stops anything; the rest
/// are read (so they don't echo as junk) and left to the caller to answer.
private enum InterruptKey {
    case ctrlC
    case other
}

/// Blocks until an interrupt key arrives; other keystrokes are ignored, and
/// EOF/read errors never count as a keypress. Only meaningful once the
/// terminal is in key-reading mode (`interceptingInterrupts`).
private func waitForInterruptKey() async throws -> InterruptKey {
    while true {
        try Task.checkCancellation()
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 100) > 0 else { continue }

        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else {
            try await Task.sleep(nanoseconds: 200_000_000)
            continue
        }
        switch byte {
        case 0x03:  // Ctrl-C
            return .ctrlC
        case 0x04, 0x71, 0x51:  // Ctrl-D, q, Q
            return .other
        case 0x1B:  // Esc, or the lead byte of an arrow key
            if case .lone = RawMode.classifyEscape() { return .other }
        default:
            continue
        }
    }
}
