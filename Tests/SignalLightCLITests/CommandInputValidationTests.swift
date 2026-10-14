import Testing

@testable import SignalLightCLICore

@Suite("Command input validation")
struct CommandInputValidationTests {
    @Test("A scan timeout must be a finite positive number")
    func scanTimeoutValidation() throws {
        try PairFlow.validateTimeout(0.1)

        for timeout in [0, -1, Double.nan, .infinity, -.infinity] {
            #expect(throws: CLIError.self) {
                try PairFlow.validateTimeout(timeout)
            }
        }
    }

    @Test("A device name cannot inject control characters into a BLE command")
    func renameRejectsControlCharacters() throws {
        try Rename.validateName("signal-light 客厅")

        for name in ["signal\nOFF", "signal\rOFF", "signal\u{0000}light"] {
            #expect(throws: CLIError.self) {
                try Rename.validateName(name)
            }
        }
    }
}
