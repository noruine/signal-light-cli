/// Product-wide identifiers shared by the CLI, daemon, and hook forwarder.
public enum SignalLightConfiguration {
    public static let cliDirectoryName = ".signal-light"
    public static let cliExecutableName = "signal-light"
    public static let hooksExecutableName = "agent-hooks"

    public static let launchAgentLabel = "app.signal-light.daemon"
    public static let launchAgentLabelEnvironmentKey = "SIGNAL_LIGHT_LAUNCHD_LABEL"
    public static let hooksBinaryEnvironmentKey = "SIGNAL_LIGHT_HOOKS_BINARY"
    public static let skipHooksEnvironmentKey = "SIGNAL_LIGHT_SKIP_HOOKS"
}
