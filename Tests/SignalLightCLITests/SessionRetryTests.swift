import Testing

@testable import SignalLightCLICore

/// Which connect failures deserve another attempt: establishment problems
/// against a just-evicted single-slot device are transient; a bluetooth
/// state problem or a rejected firmware reply would just repeat.
@Suite("Session retry policy")
struct SessionRetryTests {
    @Test("Transient establishment failures retry, state problems do not")
    func retryableSet() {
        #expect(SignalLightSessionError.connectFailed("busy").isRetryable)
        #expect(SignalLightSessionError.timedOut("连接设备").isRetryable)
        #expect(SignalLightSessionError.notReady.isRetryable)
        #expect(!SignalLightSessionError.bluetoothUnavailable("蓝牙未开启").isRetryable)
        #expect(!SignalLightSessionError.firmwareRejected("nope").isRetryable)
    }
}
