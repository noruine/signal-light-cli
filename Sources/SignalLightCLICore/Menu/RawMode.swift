import Darwin
import Dispatch
import Foundation

/// Puts stdin into cbreak mode (canonical input and echo off) for reading
/// individual keypresses, and restores the prior settings afterward. Shared
/// by the arrow-key picker and the "press Enter to continue" pause so both
/// suppress echo of stray keys — an impatient arrow-key press at a cooked
/// prompt would otherwise print raw escape bytes like `^[[B`.
///
/// `OPOST` is deliberately left on, so ordinary `print`/newlines still get
/// proper CR+LF translation while only input echoing is disabled.
enum RawMode {
    /// Puts the terminal back if a fatal signal lands while we're in raw
    /// mode: `defer restore` cannot run then, and a shell left without echo
    /// reads as "the terminal is dead".
    private static let signalGuard = RawModeSignalGuard()

    /// Switches stdin to cbreak mode and returns the previous settings for a
    /// later `restore`, or `nil` if stdin isn't a TTY or the call fails.
    /// Keys typed while no reader was watching stay queued: a deliberate
    /// Esc pressed while the next screen is still rebuilding must land.
    /// Callers that want type-ahead dropped (keys mashed during a slow
    /// action) do it themselves at their action's boundary via
    /// `discardPendingInput()`. The one exception is the interrupt
    /// watchers, which flush on entry so a stray pre-pressed Esc can't
    /// cancel the scan or flash the user just started.
    static func enter() -> termios? { enter(interceptingInterrupts: false) }

    /// Same, but with `ISIG` off as well: Ctrl-C then arrives as the byte
    /// `0x03` instead of a SIGINT. The firmware waits use this so Ctrl-C can
    /// stop them gracefully — a delivered SIGINT would kill the process with
    /// the daemon still evicted and, mid-flash, without telling the device to
    /// abort.
    static func enter(interceptingInterrupts: Bool) -> termios? {
        guard isatty(STDIN_FILENO) != 0 else { return nil }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }

        var raw = original
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        if interceptingInterrupts {
            raw.c_lflag &= ~tcflag_t(ISIG)
        }
        // VMIN=1, VTIME=0: each read blocks until at least one byte arrives.
        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        // The interrupt watchers still drop keys pressed before they armed
        // (a stray pre-pressed Esc must not cancel the operation the user
        // just started); every other reader keeps them, so a deliberate Esc
        // pressed while the next screen rebuilds still lands.
        let setMode: Int32 = interceptingInterrupts ? TCSAFLUSH : TCSADRAIN
        guard tcsetattr(STDIN_FILENO, setMode, &raw) == 0 else { return nil }
        signalGuard.arm(original)
        disableMouseReporting()
        return original
    }

    static func restore(_ original: termios) {
        disableMouseReporting()
        var original = original
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        signalGuard.disarm()
    }

    private static func disableMouseReporting() {
        FileHandle.standardOutput.write(Data("\u{1B}[?1000l\u{1B}[?1006l".utf8))
        fflush(stdout)
    }

    /// Throws away keys typed while no reader was watching (mashed during a
    /// slow action), so they can't fire on the screen that comes next.
    /// Belongs at action boundaries only: the pickers never call it while
    /// re-entering after a plain screen transition, where dropping input
    /// would eat a deliberate keypress.
    static func discardPendingInput() {
        tcflush(STDIN_FILENO, TCIFLUSH)
    }

    /// What a just-read `Esc` byte (0x1B) turned out to be.
    enum Escape {
        case lone       // a real Escape keypress → treat as cancel/back
        case up, down, left, right
        case otherSequence  // some other CSI/SS3 (Home, F-keys, …) → ignore
    }

    /// Classifies an `Esc` after it's been read: is it the user pressing
    /// Escape, or the lead byte of an arrow/function-key escape sequence?
    ///
    /// Uses a short non-blocking `poll` peek rather than a blocking read for
    /// the follow-on byte — a blocking read would hang on a *lone* Esc until
    /// the user pressed some other key, which is exactly the "Esc does nothing
    /// until I press again" bug. All key-driven pickers share this so Esc
    /// behaves identically everywhere.
    static func classifyEscape() -> Escape {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 60) > 0 else { return .lone }  // nothing followed → real Esc

        var intro: UInt8 = 0
        guard read(STDIN_FILENO, &intro, 1) == 1 else { return .lone }
        guard intro == 0x5B || intro == 0x4F else { return .lone }  // not CSI/SS3 → treat as Esc

        var final: UInt8 = 0
        guard read(STDIN_FILENO, &final, 1) == 1 else { return .lone }
        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        default:
            // Consume any remaining bytes up to the sequence's final byte so
            // they don't leak into the next read.
            if !(0x40...0x7E).contains(final) {
                var b: UInt8 = 0
                while read(STDIN_FILENO, &b, 1) == 1 {
                    if (0x40...0x7E).contains(b) { break }
                }
            }
            return .otherSequence
        }
    }
}


/// Restores the terminal when a fatal signal (Ctrl-C, `kill`, the terminal
/// closing) arrives while raw mode is active. Without it the `defer restore`
/// never runs: the shell comes back with echo off and Ctrl-C looking dead,
/// which is exactly how an exit from a picker used to feel.
private final class RawModeSignalGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.signal-light.cli.rawmode-signals")
    private var saved: termios?
    private var sources: [DispatchSourceSignal] = []
    /// Remembers the settings to put back and, once per process, installs the
    /// handlers. `SIG_IGN` first: a dispatch source only sees the signal when
    /// the default disposition isn't there to kill the process outright.
    func arm(_ settings: termios) {
        lock.lock()
        saved = settings
        let needsSources = sources.isEmpty
        lock.unlock()
        guard needsSources else { return }

        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.restoreAndReraise(number)
            }
            source.resume()
            lock.lock()
            sources.append(source)
            lock.unlock()
        }
    }

    func disarm() {
        lock.lock()
        saved = nil
        lock.unlock()
    }

    /// Put the settings back, then die the way the default disposition would
    /// have: callers must still see "killed by SIGINT", not a clean exit that
    /// hides the interrupt.
    private func restoreAndReraise(_ number: Int32) {
        lock.lock()
        let snapshot = saved
        saved = nil
        lock.unlock()

        FileHandle.standardError.write(Data("\u{1B}[?1000l\u{1B}[?1006l".utf8))
        if var snapshot {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &snapshot)
        }
        signal(number, SIG_DFL)
        raise(number)
    }
}
