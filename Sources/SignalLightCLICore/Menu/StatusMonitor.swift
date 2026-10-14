import Darwin
import Foundation
import SignalLightKit

/// Shows the current status in the menu and refreshes it while the user reads.
enum StatusMonitor {
    private static let refreshIntervalMilliseconds: Int32 = 1_000

    static func run(terminal: Terminal) {
        guard let original = RawMode.enter() else {
            terminal.out(terminal.menuBreadcrumb(CLIRuntimeContext.menuTrail))
            terminal.out("")
            StatusSnapshot.current(paths: .current()).printHumanReadable(terminal: terminal)
            return
        }
        defer { RawMode.restore(original) }

        let trail = CLIRuntimeContext.menuTrail
        let footer = terminal.keyBar([.escape("返回")])
        ScreenLayout.beginStep()

        while true {
            let snapshot = StatusSnapshot.current(paths: .current())
            ScreenLayout.paint(ScreenLayout.lines(
                terminal: terminal,
                trail: trail,
                context: [],
                body: snapshot.humanReadableLines(terminal: terminal, includeHeading: false),
                bar: footer
            ))
            if shouldReturnToMenu() { return }
        }
    }

    private static func shouldReturnToMenu() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, refreshIntervalMilliseconds) > 0 else { return false }

        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return true }
        switch byte {
        case 0x03, 0x04, 0x71, 0x51:  // Ctrl-C, Ctrl-D, q, Q
            return true
        case 0x1B:
            if case .lone = RawMode.classifyEscape() { return true }
            return false
        default:
            return false
        }
    }
}
