import Testing

@testable import SignalLightCLICore

@Suite("BLE discovery failures")
struct BLEDiscoveryTests {
    @Test("Discovery errors trigger a reconnectable failure")
    func discoveryErrorIsReported() {
        #expect(
            BLEDiscoveryFailure.reason(
                error: "connection lost",
                foundRequiredResource: false,
                resourceName: "signal light service"
            ) == "connection lost"
        )
    }

    @Test("Missing required resources are failures")
    func missingResourceIsReported() {
        #expect(
            BLEDiscoveryFailure.reason(
                error: nil,
                foundRequiredResource: false,
                resourceName: "控制特征"
            ) == "未找到控制特征"
        )
    }

    @Test("Successful discovery continues without a failure reason")
    func foundResourceIsSuccessful() {
        #expect(
            BLEDiscoveryFailure.reason(
                error: nil,
                foundRequiredResource: true,
                resourceName: "控制特征"
            ) == nil
        )
    }
}
