import Foundation
import Testing

@testable import SignalLightKit

@Suite("Daemon paths")
struct DaemonPathsTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test("The bridge socket lives inside this tool's own root")
    func bridgeSocketIsOwned() {
        let paths = SignalLightDaemonPaths(home: home)
        #expect(paths.bridgeSocketURL == paths.cliRootDir.appendingPathComponent("bridge.sock"))
        #expect(paths.ownedSockets == [paths.bridgeSocketURL])
    }

    @Test("The launchd label honors its sandbox override")
    func launchAgentLabelOverride() {
        #expect(SignalLightDaemonPaths.launchAgentLabel(environment: [:]) == "app.signal-light.daemon")
        #expect(SignalLightDaemonPaths.launchAgentLabel(
            environment: ["SIGNAL_LIGHT_LAUNCHD_LABEL": "app.signal-light.daemon.verify"]
        ) == "app.signal-light.daemon.verify")
    }

    @Test("Every inventory path stays in this tool's own namespace")
    func inventoryStaysInOwnNamespace() {
        let paths = SignalLightDaemonPaths(home: home)
        // The PATH symlink and the LaunchAgent plist are the two deliberate
        // outside-the-root entries (standard system locations); everything
        // else the tool owns must sit under ~/.signal-light.
        let inventory = paths.ownedFiles + paths.ownedSockets + paths.pruneDirsIfEmpty
        for url in inventory
        where url.path != paths.pathSymlinkURL.path && url.path != paths.launchAgentPlistURL.path {
            #expect(url.path.hasPrefix(paths.cliRootDir.path), "\(url.path) is outside the tool's own root")
        }
    }

    @Test("The prune list names every directory once, signing dir included")
    func pruneListIsDeduped() {
        let paths = SignalLightDaemonPaths(home: home)
        let standardized = paths.pruneDirsIfEmpty.map(\.standardizedFileURL.path)
        #expect(Set(standardized).count == standardized.count)
        #expect(paths.pruneDirsIfEmpty.contains(paths.devSigningDir))
    }

    @Test("The signing certificate is part of the uninstall inventory")
    func signingCertificateIsOwned() {
        let paths = SignalLightDaemonPaths(home: home)
        #expect(paths.ownedFiles.contains(paths.devSigningCertURL))
    }
}
