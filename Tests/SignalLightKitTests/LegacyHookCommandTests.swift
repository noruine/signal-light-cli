import Foundation
import Testing

@testable import SignalLightKit

@Suite("Legacy hook commands")
struct LegacyHookCommandTests {
    @Test("Old product names are recognized through shell quoting")
    func oldProductNames() {
        #expect(LegacyHookCommand.matches("'/Users/someone/.open-island/bin/OpenIslandHooks'"))
        #expect(LegacyHookCommand.matches("'/Applications/Vibe Island.app/Contents/Helpers/VibeIslandHooks' --source codex"))
    }

    @Test("Environment prefixes do not hide the executable")
    func environmentPrefix() {
        #expect(LegacyHookCommand.matches("SIGNAL_LIGHT_SKIP_HOOKS=1 /usr/local/bin/open-island-bridge run"))
    }

    @Test("Only the executable's basename is matched")
    func basenameOnly() {
        #expect(!LegacyHookCommand.matches("echo vibeislandhooks"))
        #expect(!LegacyHookCommand.matches("python3 /Users/someone/hooks/openislandhooks-helper.py"))
        #expect(!LegacyHookCommand.matches("'/Users/someone/.signal-light/bin/agent-hooks'"))
    }
}
