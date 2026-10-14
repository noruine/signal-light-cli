import Testing

@testable import SignalLightCLICore

@Suite("Effect interval validation")
struct ConfigFormatTests {
    @Test("Solid effects allow zero interval")
    func solidAllowsZeroInterval() {
        #expect(ConfigFormat.intervalValidationError(0, for: .solid) == nil)
    }

    @Test("Animated effects require a positive interval")
    func animatedEffectsRequirePositiveInterval() {
        #expect(ConfigFormat.intervalValidationError(0, for: .blink)?.message.contains("大于 0") == true)
    }

    @Test("All effects reject negative intervals")
    func negativeIntervalIsRejected() {
        #expect(ConfigFormat.intervalValidationError(-1, for: .solid)?.message == "间隔不能是负数。")
    }
}
