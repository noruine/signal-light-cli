import Foundation
import Testing

import SignalLightKit

@Suite("Executable installation")
struct ExecutableInstallerTests {
    @Test("A failed copy preserves the installed executable")
    func failedCopyPreservesDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("bin/signal-light")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("installed executable".utf8)
        try original.write(to: destination)

        #expect(throws: (any Error).self) {
            try ExecutableInstaller.replace(
                from: root.appendingPathComponent("missing-source"),
                to: destination
            )
        }

        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path
        ) == ["signal-light"])
    }

    @Test("A staged copy replaces the executable and sets its mode")
    func stagedCopyReplacesDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("new-build")
        let destination = root.appendingPathComponent("bin/signal-light")
        try Data("new executable".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old executable".utf8).write(to: destination)

        try ExecutableInstaller.replace(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == Data("new executable".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path
        ) == ["signal-light"])
    }

    @Test("A symlinked build is installed as a standalone executable")
    func symlinkedSourceIsResolvedBeforeInstall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("real-agent-hooks")
        let source = root.appendingPathComponent("agent-hooks")
        let destination = root.appendingPathComponent("bin/agent-hooks")
        try Data("hooks executable".utf8).write(to: binary)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: binary)

        try ExecutableInstaller.replace(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == Data("hooks executable".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
    }

    @Test("A directory cannot replace the installed executable")
    func directorySourceIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("build-output", isDirectory: true)
        let destination = root.appendingPathComponent("bin/signal-light")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("installed executable".utf8)
        try original.write(to: destination)

        #expect(throws: ExecutableInstallerError.sourceIsNotRegularFile(source)) {
            try ExecutableInstaller.replace(from: source, to: destination)
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("Hooks binary install preserves the previous copy when staging fails")
    func hooksBinaryInstallPreservesDestinationOnFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("agent-hooks")
        let destination = root.appendingPathComponent("bin/agent-hooks")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("previous hooks binary".utf8)
        try original.write(to: destination)

        #expect(throws: (any Error).self) {
            try ManagedHooksBinary.install(
                from: source,
                to: destination
            )
        }

        #expect(try Data(contentsOf: destination) == original)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-executable-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
