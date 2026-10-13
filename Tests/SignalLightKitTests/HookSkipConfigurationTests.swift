import Testing

@testable import SignalLightKit

@Suite("Hook skip switch")
struct HookSkipConfigurationTests {
    @Test("SIGNAL_LIGHT_SKIP_HOOKS=1 keeps a child out of the light")
    func skipKeyWorks() {
        #expect(HookSkipConfiguration.shouldSkipHooks(environment: ["SIGNAL_LIGHT_SKIP_HOOKS": "1"]))
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: ["SIGNAL_LIGHT_SKIP_HOOKS": "0"]))
    }

    @Test("The pre-rename OPEN_ISLAND key no longer does anything")
    func oldKeyIsIgnored() {
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: ["OPEN_ISLAND_SKIP_HOOKS": "1"]))
    }
}
