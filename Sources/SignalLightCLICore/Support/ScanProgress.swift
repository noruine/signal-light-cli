import Darwin
import Foundation

/// Draws the pairing scan as a screen carrying the same shell as everything
/// else: breadcrumb (bare CLI runs only — inside the menu the result screen
/// already shows it), the live spinner line as the body, then the key bar.
/// The frame is written once; the timer only ever repaints the body line,
/// wherever the shell put it. All writes happen on `queue`, so the frame and
/// the ticks can never interleave.
///
/// On a non-interactive stderr (piped/redirected) it degrades to one plain
/// line per phase and never emits carriage-return animation, keeping logs
/// clean. Thread-safe: phase changes arrive on the BLE scanner's queue.
final class ScanProgress: @unchecked Sendable {
    private enum Phase {
        case waitingForBluetooth
        case scanning(deadline: Date)
        case finalizing
    }

    private let animated: Bool
    private let terminal: Terminal
    private let lock = NSLock()
    private var phase: Phase?
    private var frame = 0
    private var frameStarted = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.signal-light.scanprogress")
    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// No breadcrumb of its own: inside the menu the result screen already
    /// printed it, and a bare CLI run stays Unix-plain.
    init(terminal: Terminal) {
        self.terminal = terminal
        animated = terminal.isInteractive && isatty(STDERR_FILENO) != 0
    }

    func waitingForBluetooth() {
        lock.lock()
        phase = .waitingForBluetooth
        lock.unlock()
        if animated {
            startDrawing()
        } else {
            writeLine("⚠️  蓝牙未开启，请在控制中心或系统设置中打开；打开后会继续扫描…\n")
        }
    }

    func scanning(seconds: TimeInterval) {
        lock.lock()
        phase = .scanning(deadline: Date().addingTimeInterval(seconds))
        lock.unlock()
        if animated {
            startDrawing()
        } else {
            writeLine("🔍  正在扫描红绿灯设备（最多 \(Int(seconds))s，找到即停）…\n")
        }
    }

    /// A device is already in hand; the countdown stops and we just wait a
    /// beat for any others.
    func finalizing() {
        lock.lock()
        phase = .finalizing
        lock.unlock()
        if animated {
            startDrawing()
        } else {
            writeLine("🔍  已找到红绿灯，正在确认…\n")
        }
    }

    /// Stops the animation and erases the whole frame so the next output
    /// starts clean. Safe to call more than once.
    func finish() {
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            if MenuActionScreen.isActive() {
                MenuActionScreen.finishProgress()
                frameStarted = false
                return
            }
            guard animated, frameStarted else { return }
            frameStarted = false
            // Clear the body line, the blank, and the bar — then put the
            // cursor back on the body line, so whatever prints next (the
            // cancel notice, an error, the picker) starts right under the
            // header instead of floating below an erased frame.
            writeLine("\r\u{1B}[K\n\r\u{1B}[K\n\r\u{1B}[K\u{1B}[2A\r")
        }
    }

    private func startDrawing() {
        queue.async { [self] in
            guard timer == nil else { return }
            drawFrameIfNeeded()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(120))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func drawFrameIfNeeded() {
        guard !frameStarted else { return }
        frameStarted = true
        if MenuActionScreen.isActive() {
            MenuActionScreen.setFooter(terminal.keyBar([.escape("取消")]))
            _ = MenuActionScreen.replaceProgress("正在扫描红绿灯设备…")
            return
        }
        let lines = ScreenLayout.lines(
            terminal: terminal,
            trail: nil,
            context: [],
            body: [" "],
            bar: terminal.keyBar([.escape("取消")])
        )
        let bodyIndex = lines.count - 3  // [.., body, blank, bar]
        var text = ""
        for line in lines[..<bodyIndex] {
            text += line + "\n"
        }
        text += "\n"                        // the body line, left for the timer
        text += lines[bodyIndex + 1] + "\n"  // the blank
        text += lines[bodyIndex + 2]          // the bar
        text += "\u{1B}[2A\r"               // back up to the body line
        writeLine(text)
    }

    private func tick() {
        lock.lock()
        let phase = phase
        let spin = Self.spinner[frame % Self.spinner.count]
        frame += 1
        lock.unlock()

        let message: String
        switch phase {
        case .waitingForBluetooth:
            message = "\(spin)  蓝牙未开启，去控制中心或系统设置里打开，打开后自动继续"
        case let .scanning(deadline):
            let remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            message = "\(spin)  正在扫描红绿灯设备…剩余 \(remaining)s（找到即停）"
        case .finalizing:
            message = "\(spin)  已找到红绿灯，正在确认…"
        case .none:
            return
        }
        if MenuActionScreen.isActive() {
            MenuActionScreen.setFooter(terminal.keyBar([.escape("取消")]))
            _ = MenuActionScreen.replaceProgress(message)
            return
        }
        writeLine("\r\u{1B}[K\(message)")
    }

    private func writeLine(_ text: String) {
        if MenuActionScreen.isActive() {
            let message = text
                .replacingOccurrences(of: "\r\u{1B}[K", with: "")
                .trimmingCharacters(in: .newlines)
            MenuActionScreen.setFooter(terminal.keyBar([.escape("取消")]))
            _ = MenuActionScreen.replaceProgress(message)
            return
        }
        FileHandle.standardError.write(Data(text.utf8))
    }
}
