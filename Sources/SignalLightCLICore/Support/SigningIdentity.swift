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

    /// Where a user-level identity lives; the one place `sign` imports into
    /// and `uninstall` deletes from.
    static func loginKeychain(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Keychains", isDirectory: true)
            .appendingPathComponent("login.keychain-db")
    }

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
        guard FileManager.default.fileExists(atPath: keychain.path) else {
            throw CLIError(
                "找不到登录钥匙串：\(PathText.abbreviated(keychain))。签名身份要导入那里，请确认钥匙串存在后重试。",
                exitCode: .noInput
            )
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let certURL = storeDirectory.appendingPathComponent("cert.pem")

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let keyURL = workDirectory.appendingPathComponent("key.pem")
        let p12URL = workDirectory.appendingPathComponent("identity.p12")
        // A throwaway password for the temporary .p12. Empty does not work:
        // `security import -P ""` dies with "MAC verification failed during
        // PKCS12 import (wrong password?)", naming the wrong cause.
        let password = UUID().uuidString

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
                "-out", p12URL.path, "-passout", "pass:\(password)",
            ],
            failureContext: "打包签名身份失败",
            processRunner: processRunner
        )
        // Read the package back before `security` ever sees it, so a bad
        // export fails as what it is instead of surfacing as an import error.
        try runChecked(
            openssl,
            arguments: ["pkcs12", "-info", "-noout", "-in", p12URL.path, "-passin", "pass:\(password)"],
            failureContext: "校验打包好的签名身份失败",
            processRunner: processRunner
        )
        // `-A` plus `-T codesign` lets codesign use the key without asking
        // for authorization on every signature.
        let imported = try processRunner.run(
            security,
            arguments: ["import", p12URL.path, "-k", keychain.path, "-P", password, "-T", codesign.path, "-A"]
        )
        guard imported.exitCode == 0 else {
            // Leave nothing half-done: without the keychain entry the
            // certificate is scrap, and the next attempt regenerates both.
            try? FileManager.default.removeItem(at: certURL)
            if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path), leftovers.isEmpty {
                try? FileManager.default.removeItem(at: storeDirectory)
            }
            let detail = (imported.stderr + imported.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(
                "导入签名身份失败\(detail.isEmpty ? "" : "：\(detail)")。这次没有留下任何文件，可直接重试。",
                exitCode: .software
            )
        }
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

    /// Best-effort removal of the identity for `uninstall`'s "as if it was
    /// never here" promise: trust settings first (that step needs the
    /// certificate file), then the keychain entry — which takes the private
    /// key with it. Returns what was actually removed, so the caller reports
    /// only real removals and a machine that never ran `sign` stays silent.
    static func removeIdentity(
        storeDirectory: URL,
        keychain: URL,
        processRunner: ProcessRunning = SystemProcessRunner()
    ) -> (trustRemoved: Bool, identityRemoved: Bool) {
        let certURL = storeDirectory.appendingPathComponent("cert.pem")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: certURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fingerprint = certificateFingerprint(at: certURL, processRunner: processRunner) else {
            return (false, false)
        }

        var trustRemoved = false
        if let result = try? processRunner.run(security, arguments: ["remove-trusted-cert", certURL.path]) {
            trustRemoved = result.exitCode == 0
        }
        var identityRemoved = false
        if let result = try? processRunner.run(
            security,
            arguments: ["delete-identity", "-Z", fingerprint, keychain.path]
        ) {
            identityRemoved = result.exitCode == 0
        }
        return (trustRemoved, identityRemoved)
    }

    private static func certificateFingerprint(at certificateURL: URL, processRunner: ProcessRunning) -> String? {
        guard let result = try? processRunner.run(
            openssl,
            arguments: ["x509", "-in", certificateURL.path, "-noout", "-fingerprint", "-sha256"]
        ), result.exitCode == 0,
              let fingerprintLine = (result.stdout + result.stderr)
                  .split(whereSeparator: \.isNewline)
                  .first(where: { $0.localizedCaseInsensitiveContains("sha256 fingerprint=") }),
              let separator = fingerprintLine.firstIndex(of: "=") else {
            return nil
        }

        let fingerprint = fingerprintLine[fingerprintLine.index(after: separator)...]
            .filter { $0 != ":" && !$0.isWhitespace }
            .uppercased()
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return fingerprint
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
