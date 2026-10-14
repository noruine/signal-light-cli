import Foundation
import Testing

@testable import SignalLightCLICore

@Suite("Firmware download files")
struct FirmwareUpdateTests {
    @Test("Download paths never reuse or remove a user's same-version file")
    func downloadPathsAreUnique() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-firmware-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("signal-light-firmware-1.2.3.bin")
        let original = Data("user file".utf8)
        try original.write(to: existing)

        let first = FirmwareUpdateChecker.temporaryFirmwareURL(in: directory)
        let second = FirmwareUpdateChecker.temporaryFirmwareURL(in: directory)

        #expect(first != second)
        #expect(first.deletingLastPathComponent() == directory)
        #expect(first.lastPathComponent.hasPrefix("signal-light-firmware-"))
        #expect(first.pathExtension == "bin")
        #expect(try Data(contentsOf: existing) == original)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }
}
