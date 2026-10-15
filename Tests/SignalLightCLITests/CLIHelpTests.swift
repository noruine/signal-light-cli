import Testing

@testable import SignalLightCLICore

@Suite("CLI help")
struct CLIHelpTests {
    @Test("Help uses the --help flag and shows only working output options")
    func helpFlagAndOutputOptions() {
        let help = SignalLightCLIEntry.localizedHelp(arguments: ["service", "start", "--help"])
        #expect(help?.contains("说明：") == true)
        #expect(help?.contains("--color") == true)
        #expect(help?.contains("--quiet") == true)
        #expect(help?.contains("隐藏过程提示，保留最终结果。") == true)
        #expect(help?.contains("--verbose") != true)
    }

    @Test("The legacy help syntax points users to --help")
    func legacyHelpSyntaxIsRejected() {
        let error = SignalLightCLIEntry.legacyHelpSyntaxError(arguments: ["help", "service", "start"])
        #expect(error?.message == "帮助请使用 --help 查看。")
        #expect(SignalLightCLIEntry.legacyHelpSyntaxError(arguments: ["status"])?.message == nil)
        #expect(SignalLightCLIEntry.localizedHelp(arguments: ["help", "service", "start"]) == nil)
    }
}
