import Darwin
import Foundation

/// Draws a single, self-updating status line on stderr while `pair` waits on
/// Bluetooth — a moving spinner plus a live scan countdown, so the user can
/// see the tool is actually working rather than staring at a frozen "(8s)".
///
/// On a non-interactive stderr (piped/redirected) it degrades to one plain
/// line per phase and never emits carriage-return animation, keeping logs
/// clean. Thread-safe: phase changes arrive on the BLE scanner's queue while
/// the redraw timer runs on its own queue.
final class ScanProgress: @unchecked Sendable {
    private enum Phase {
        case waitingForBluetooth
        case scanning(deadline: Date)
        case finalizing
    }

    private let animated: Bool
    private let lock = NSLock()
    private var phase: Phase?
    private var frame = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.signal-light.scanprogress")
    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(terminal: Terminal) {
        animated = terminal.isInteractive && isatty(STDERR_FILENO) != 0
    }

    func waitingForBluetooth() {
        lock.lock()
        phase = .waitingForBluetooth
        lock.unlock()
        if animated {
            startTimerIfNeeded()
        } else {
            writeLine("⚠️  蓝牙未开启，请在控制中心或系统设置中打开；打开后会继续扫描…\n")
        }
    }

    func scanning(seconds: TimeInterval) {
        lock.lock()
        phase = .scanning(deadline: Date().addingTimeInterval(seconds))
        lock.unlock()
        if animated {
            startTimerIfNeeded()
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
            startTimerIfNeeded()
        } else {
            writeLine("🔍  已找到红绿灯，正在确认…\n")
        }
    }

    /// Stops the animation and clears the status line so the next output
    /// starts clean. Safe to call more than once.
    func finish() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
        if animated {
            writeLine("\r\u{1B}[K")  // erase the status line in place
        }
    }

    private func startTimerIfNeeded() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(120))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
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
        writeLine("\r\u{1B}[K\(message)")
    }

    private func writeLine(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
