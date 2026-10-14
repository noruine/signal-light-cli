import Testing

@testable import SignalLightCLICore

/// Which connect failures deserve another attempt: establishment problems
/// against a just-evicted single-slot device are transient; a bluetooth
/// state problem or a rejected firmware reply would just repeat.
@Suite("Session retry policy")
struct SessionRetryTests {
    @Test("A session is ready only after control notifications are enabled")
    func readinessWaitsForNotifications() {
        var readiness = BLESessionReadiness()
        #expect(!readiness.isReady)

        readiness.didDiscoverCharacteristics(hasCommand: true, hasControl: true)
        #expect(!readiness.isReady)

        readiness.didEnableControlNotifications(true)
        #expect(readiness.isReady)
    }

    @Test("Missing required characteristics or notifications keep a session unready")
    func readinessRequiresAllCapabilities() {
        var readiness = BLESessionReadiness()
        readiness.didDiscoverCharacteristics(hasCommand: true, hasControl: false)
        readiness.didEnableControlNotifications(true)
        #expect(!readiness.isReady)

        readiness.didDiscoverCharacteristics(hasCommand: true, hasControl: true)
        readiness.didEnableControlNotifications(false)
        #expect(!readiness.isReady)
    }

    @Test("Firmware cancellation recognizes Esc as well as Ctrl-C")
    func cancellationKeys() {
        #expect(InterruptKey.escape.isCancellation)
        #expect(InterruptKey.ctrlC.isCancellation)
        #expect(!InterruptKey.other.isCancellation)
    }

    @Test("Transient establishment failures retry, state problems do not")
    func retryableSet() {
        #expect(SignalLightSessionError.connectFailed("busy").isRetryable)
        #expect(SignalLightSessionError.timedOut("连接设备").isRetryable)
        #expect(SignalLightSessionError.notReady.isRetryable)
        #expect(!SignalLightSessionError.bluetoothUnavailable("蓝牙未开启").isRetryable)
        #expect(!SignalLightSessionError.firmwareRejected("nope").isRetryable)
    }
}
