import Foundation

/// The local self-signed identity installed builds are signed with.
///
/// TCC keys a Bluetooth grant for an ad-hoc binary by its cdhash, so every
/// rebuild silently invalidates the previous grant. Signing with a
/// certificate makes TCC track its designated requirement instead, which
/// survives rebuilds. `signal-light sign` creates the identity once;
/// `install`/`upgrade` only ever reuse it — creation opens an authorization
/// prompt and must stay behind an explicit command.
enum SigningIdentity {
    static let name = "Signal Light Dev Local"

    private static let security = URL(fileURLWithPath: "/usr/bin/security")
    private static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
    private static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")

    /// Whether `codesign --sign "<name>"` would find a usable identity.
    /// `find-identity -v` lists only valid (trusted) ones on purpose.
    static func isAvailable(processRunner: ProcessRunning = SystemProcessRunner()) -> Bool {
        guard let result = try? processRunner.run(
            security,
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        ) else {
            return false
        }
        return (result.stdout + result.stderr).contains(name)
    }

    /// Generates a self-signed certificate under `storeDirectory` and imports
    /// it with its key into the login keychain. The private key only lives in
    /// the keychain; the temporary copies are removed. Returns the stable
    /// certificate path — the trust step and the printed manual fallback both
    /// need it.
    static func importIdentity(
        storeDirectory: URL,
        keychain: URL,
        processRunner: ProcessRunning = SystemProcessRunner()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let certURL = storeDirectory.appendingPathComponent("cert.pem")

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let keyURL = workDirectory.appendingPathComponent("key.pem")
        let p12URL = workDirectory.appendingPathComponent("identity.p12")

        try runChecked(
            openssl,
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
                "-keyout", keyURL.path, "-out", certURL.path,
                "-subj", "/CN=\(name)",
                "-addext", "keyUsage=digitalSignature",
                "-addext", "extendedKeyUsage=codeSigning",
            ],
            failureContext: "生成自签名证书失败",
            processRunner: processRunner
        )
        try runChecked(
            openssl,
            arguments: [
                "pkcs12", "-export", "-inkey", keyURL.path, "-in", certURL.path,
                "-out", p12URL.path, "-passout", "pass:",
            ],
            failureContext: "打包签名身份失败",
            processRunner: processRunner
        )
        // `-A` plus `-T codesign` lets codesign use the key without asking
        // for authorization on every signature.
        try runChecked(
            security,
            arguments: ["import", p12URL.path, "-k", keychain.path, "-P", "", "-T", codesign.path, "-A"],
            failureContext: "导入签名身份失败",
            processRunner: processRunner
        )
        return certURL
    }

    /// Trusts the certificate for code signing — macOS shows one
    /// authorization prompt here. Returns `false` when it did not complete
    /// (canceled, or no way to ask), so the caller can print the manual
    /// command instead of raw `security` noise.
    static func trustIdentity(
        certURL: URL,
        keychain: URL,
        processRunner: ProcessRunning = SystemProcessRunner()
    ) throws -> Bool {
        let result = try processRunner.run(
            security,
            arguments: ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain.path, certURL.path]
        )
        return result.exitCode == 0
    }

    /// The command that finishes the trust step by hand, for when the
    /// authorization dialog was canceled or could not be shown.
    static func manualTrustCommand(certURL: URL, keychain: URL) -> String {
        "security add-trusted-cert -r trustRoot -p codeSign -k \"\(keychain.path)\" \"\(certURL.path)\""
    }

    /// Signs one installed binary, replacing whatever signature it carries.
    static func sign(_ binary: URL, processRunner: ProcessRunning = SystemProcessRunner()) throws {
        try runChecked(
            codesign,
            arguments: ["--force", "--sign", name, binary.path],
            failureContext: "签名 \(binary.lastPathComponent) 失败",
            processRunner: processRunner
        )
    }

    private static func runChecked(
        _ executableURL: URL,
        arguments: [String],
        failureContext: String,
        processRunner: ProcessRunning
    ) throws {
        let result = try processRunner.run(executableURL, arguments: arguments)
        guard result.exitCode == 0 else {
            let detail = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("\(failureContext)\(detail.isEmpty ? "" : "：\(detail)")", exitCode: .software)
        }
    }
}
