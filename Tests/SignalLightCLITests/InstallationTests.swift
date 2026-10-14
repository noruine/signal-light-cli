import Foundation
import Testing

import SignalLightKit
@testable import SignalLightCLICore

@Suite("Installation path ownership")
struct InstallationTests {
    @Test("A foreign command at the PATH destination is preserved")
    func foreignPathCommandIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-install-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SignalLightDaemonPaths(home: root)
        try FileManager.default.createDirectory(at: paths.pathSymlinkDir, withIntermediateDirectories: true)
        let original = Data("owned by another tool".utf8)
        try original.write(to: paths.pathSymlinkURL)

        #expect(throws: CLIError.self) {
            try Installation.linkIntoPath(
                paths: paths,
                terminal: Terminal(colorMode: .never, environment: [:])
            )
        }
        #expect(try Data(contentsOf: paths.pathSymlinkURL) == original)
    }

    @Test("A dangling foreign symlink is preserved")
    func danglingForeignPathLinkIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-install-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SignalLightDaemonPaths(home: root)
        try FileManager.default.createDirectory(at: paths.pathSymlinkDir, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("another-tool")
        try FileManager.default.createSymbolicLink(at: paths.pathSymlinkURL, withDestinationURL: target)

        #expect(throws: CLIError.self) {
            try Installation.validatePathDestination(paths: paths)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.pathSymlinkURL.path) == target.path)
    }
}
