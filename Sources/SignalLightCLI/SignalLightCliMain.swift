import SignalLightCLICore

/// Thin executable entry — every real line lives in `SignalLightCLICore`, so
/// the test target can import the module instead of this shell.
@main
struct SignalLightCLIMain {
    static func main() async {
        await SignalLightCLIEntry.run()
    }
}
