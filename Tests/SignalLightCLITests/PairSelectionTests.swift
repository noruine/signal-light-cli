import Foundation
import Testing

@testable import SignalLightCLICore

@Suite("Pair device selection")
struct PairSelectionTests {
    private let terminal = Terminal(colorMode: .never, environment: [:])
    private let devices = [
        SignalLightBLEDaemon.DiscoveredDevice(
            name: "signal-light kitchen",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ),
        SignalLightBLEDaemon.DiscoveredDevice(
            name: "signal-light office",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ),
    ]

    @Test("A partial name must not choose the first of multiple devices")
    func ambiguousNameIsRejected() {
        #expect(throws: CLIError.self) {
            try PairFlow.selectDevice(
                from: devices,
                terminal: terminal,
                device: "signal-light",
                first: false,
                trail: nil
            )
        }
    }

    @Test("A full UUID selects the intended device")
    func fullIdentifierSelectsOneDevice() throws {
        let selected = try PairFlow.selectDevice(
            from: devices,
            terminal: terminal,
            device: "00000000-0000-0000-0000-000000000002",
            first: false,
            trail: nil
        )

        #expect(selected == devices[1])
    }
}
