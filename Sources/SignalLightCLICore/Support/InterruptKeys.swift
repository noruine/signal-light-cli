import Darwin
import Foundation

/// What the just-read interrupt key was. Ctrl-C and a lone Esc are distinct
/// cancellation keys; other keys are consumed so they cannot leak into a
/// later prompt.
enum InterruptKey: Equatable {
    case ctrlC
    case escape
    case other

    var isCancellation: Bool {
        self == .ctrlC || self == .escape
    }
}

/// Blocks until an interrupt key arrives; other keystrokes are ignored, and
/// EOF/read errors never count as a keypress. Only meaningful once the
/// terminal is in key-reading mode (`RawMode.enter(interceptingInterrupts:)`).
func waitForInterruptKey() async throws -> InterruptKey {
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
            if case .lone = RawMode.classifyEscape() { return .escape }
        default:
            continue
        }
    }
}
