import Foundation
import Testing

@testable import SignalLightCLICore

@Suite("Signing identity ownership")
struct SigningIdentityTests {
    private let fingerprint = String(repeating: "A1", count: 32)

    @Test("A missing certificate never deletes a same-name identity")
    func missingCertificateIsNotAuthorityToDelete() throws {
        let store = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        let runner = RecordingProcessRunner(fingerprintOutput: fingerprintOutput)

        let removal = SigningIdentity.removeIdentity(storeDirectory: store, keychain: store.appendingPathComponent("login"), processRunner: runner)

        #expect(!removal.trustRemoved)
        #expect(!removal.identityRemoved)
        #expect(runner.calls.isEmpty)
    }

    @Test("A certificate symlink cannot authorize keychain deletion")
    func certificateSymlinkIsNotTrustedAsOwned() throws {
        let store = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        let externalCertificate = store.deletingLastPathComponent().appendingPathComponent("foreign-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: externalCertificate) }
        try Data("foreign certificate".utf8).write(to: externalCertificate)
        try FileManager.default.createSymbolicLink(
            at: store.appendingPathComponent("cert.pem"),
            withDestinationURL: externalCertificate
        )
        let runner = RecordingProcessRunner(fingerprintOutput: fingerprintOutput)

        let removal = SigningIdentity.removeIdentity(storeDirectory: store, keychain: store.appendingPathComponent("login"), processRunner: runner)

        #expect(!removal.trustRemoved)
        #expect(!removal.identityRemoved)
        #expect(runner.calls.isEmpty)
    }

    @Test("Removal targets the certificate fingerprint from the owned file")
    func removalUsesCertificateFingerprint() throws {
        let store = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        try Data("owned certificate".utf8).write(to: store.appendingPathComponent("cert.pem"))
        let keychain = store.appendingPathComponent("login")
        let runner = RecordingProcessRunner(fingerprintOutput: fingerprintOutput)

        let removal = SigningIdentity.removeIdentity(storeDirectory: store, keychain: keychain, processRunner: runner)

        #expect(removal.trustRemoved)
        #expect(removal.identityRemoved)
        #expect(runner.calls.contains { $0.arguments == ["delete-identity", "-Z", fingerprint, keychain.path] })
        #expect(!runner.calls.contains { $0.arguments.contains("-c") })
    }

    private var fingerprintOutput: String {
        "SHA256 Fingerprint=" + stride(from: 0, to: fingerprint.count, by: 2)
            .map { String(fingerprint.dropFirst($0).prefix(2)) }
            .joined(separator: ":")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private let fingerprintOutput: String
    private var recordedCalls: [Call] = []

    init(fingerprintOutput: String) {
        self.fingerprintOutput = fingerprintOutput
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult {
        lock.lock()
        recordedCalls.append(Call(executable: executableURL, arguments: arguments))
        lock.unlock()
        let output = executableURL.lastPathComponent == "openssl" ? fingerprintOutput : ""
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }
}
