import SignalLightKit

/// The 「接入 Agent」 item of the interactive menu. The checkbox screen itself
/// lives in `HooksAgentSetup` (shared with the no-argument
/// `signal-light hooks install`); when it did something, this holds the report
/// on screen before the menu redraws. Backing out with Esc returns quietly —
/// the previous page is the whole answer.
enum HooksMenu {
    static func run(terminal: Terminal) async {
        guard await HooksAgentSetup.run(paths: SignalLightDaemonPaths.current(), terminal: terminal) else {
            return
        }
        MenuPrompt.pause(terminal)
    }
}
