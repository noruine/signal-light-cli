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
        try Data().write(to: paths.bridgeSocketURL)
        return (home, paths)
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
}
