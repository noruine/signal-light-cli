import Foundation
import Testing

@testable import SignalLightCLICore
import SignalLightKit

@Suite("Audit inventory")
struct AuditTests {
    @Test("Owned files display beneath their managed directory")
    func inventoryLabelsShowDirectoryTree() {
        let paths = SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp/audit-home"))
        let directories = Set(paths.pruneDirsIfEmpty.map(\.standardizedFileURL.path))

        #expect(Audit.inventoryLabel(paths.cliRootDir, root: paths.cliRootDir, directories: directories)
            == "/tmp/audit-home/.signal-light/")
        #expect(Audit.inventoryLabel(paths.binDir, root: paths.cliRootDir, directories: directories)
            == "  bin/")
        #expect(Audit.inventoryLabel(paths.hooksBinaryURL, root: paths.cliRootDir, directories: directories)
            == "    agent-hooks")
        #expect(Audit.inventoryLabel(paths.stateJSONURL, root: paths.cliRootDir, directories: directories)
            == "  state.json")
        #expect(Audit.inventoryLabel(paths.pathSymlinkURL, root: paths.cliRootDir, directories: directories)
            == "/tmp/audit-home/.local/bin/signal-light")
    }
}
