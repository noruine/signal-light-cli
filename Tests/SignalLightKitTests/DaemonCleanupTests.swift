import Darwin
import Foundation
import Testing

@testable import SignalLightKit

@Suite("Daemon cleanup")
struct DaemonCleanupTests {
    private func makeHome() throws -> (home: URL, paths: SignalLightDaemonPaths) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let paths = SignalLightDaemonPaths(home: home)
        try FileManager.default.createDirectory(at: paths.cliRootDir, withIntermediateDirectories: true)
        try createSocketFile(at: paths.bridgeSocketURL)
        return (home, paths)
    }

    private func createSocketFile(at url: URL) throws {
        var address = try #require(UnixSocket.address(for: url.path))
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let result = UnixSocket.withSockaddr(&address) { bind(descriptor, $0, $1) }
        #expect(result == 0)
    }

    @Test("A dead socket file is removed, and the emptied root goes with it")
    func deadSocketIsRemoved() throws {
        let (home, paths) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: { _ in true })

        #expect(report.removedFiles.contains(paths.bridgeSocketURL))
        #expect(report.removedDirs.contains(paths.cliRootDir))
        #expect(!FileManager.default.fileExists(atPath: paths.bridgeSocketURL.path))
    }

    @Test("A socket probed live once never comes back as residue")
    func liveSocketProbeFlipStaysOutOfResidue() throws {
        let (home, paths) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // First probe (the cleanup pass): live, so the socket is kept. Second
        // probe (the verification pass): a wedged listener whose accept
        // backlog reads full can refuse connect — the exact flip that used to
        // make cleanup fail over the socket it rightly kept.
        var probes = 0
        let socketIsInactive: (URL) -> Bool = { _ in
            probes += 1
            return probes > 1
        }

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: socketIsInactive)

        #expect(report.liveSockets.contains(paths.bridgeSocketURL))
        #expect(!report.remaining.contains(paths.bridgeSocketURL))
        #expect(FileManager.default.fileExists(atPath: paths.bridgeSocketURL.path))
    }

    @Test("A directory at the socket path is kept as a foreign entry")
    func socketPathDirectoryIsPreserved() throws {
        let (home, paths) = try makeHome()
        try FileManager.default.removeItem(at: paths.bridgeSocketURL)
        try FileManager.default.createDirectory(at: paths.bridgeSocketURL, withIntermediateDirectories: false)
        let marker = paths.bridgeSocketURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: home) }

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: { _ in true })

        #expect(report.keptForeignEntries.contains(paths.bridgeSocketURL))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test("A regular file at the socket path is preserved")
    func socketPathRegularFileIsPreserved() throws {
        let (home, paths) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.removeItem(at: paths.bridgeSocketURL)
        let contents = Data("foreign file".utf8)
        try contents.write(to: paths.bridgeSocketURL)
        var probeCount = 0

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: { _ in
            probeCount += 1
            return true
        })

        #expect(probeCount == 0)
        #expect(report.keptForeignEntries.contains(paths.bridgeSocketURL))
        #expect(try Data(contentsOf: paths.bridgeSocketURL) == contents)
    }

    @Test("A symlink at the socket path is preserved")
    func socketPathSymlinkIsPreserved() throws {
        let (home, paths) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.removeItem(at: paths.bridgeSocketURL)
        let target = home.appendingPathComponent("foreign.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.bridgeSocketURL, withDestinationURL: target)

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: { _ in true })

        #expect(report.keptForeignEntries.contains(paths.bridgeSocketURL))
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: paths.bridgeSocketURL.path)) != nil)
    }

    @Test("A foreign LaunchAgent plist is preserved during cleanup")
    func foreignLaunchAgentIsPreserved() throws {
        let (home, paths) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        let foreign = try LaunchAgentSpec(
            label: "another.product.agent",
            programArguments: ["/usr/local/bin/another-product", "run"],
            stdoutPath: "/tmp/another.log",
            stderrPath: "/tmp/another.log",
            runAtLoad: true
        ).serialize()
        try foreign.write(to: paths.launchAgentPlistURL)

        let report = try DaemonCleanup.perform(paths: paths, socketIsInactive: { _ in true })

        #expect(report.keptForeignEntries.contains(paths.launchAgentPlistURL))
        #expect(try Data(contentsOf: paths.launchAgentPlistURL) == foreign)
    }
}
