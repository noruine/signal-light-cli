import ArgumentParser
import Foundation
import SignalLightKit

/// One-time setup of this machine's signing identity, plus signing whatever
/// is installed right now. Idempotent: an existing identity is reused, and
/// binaries that already carry a stable signature are left alone.
struct Sign: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "配置固定签名，让重建的程序沿用蓝牙授权。",
        discussion: """
        macOS 按签名身份记录蓝牙权限：临时签名每次重建都换，权限会失效。
        sign 创建一张本机自签名证书（只进登录钥匙串），用它签名已安装的
        程序；之后每次 install / upgrade 都自动沿用这个签名。

        创建证书时 macOS 请求一次授权；后台服务在运行的话，签名后会重启
        一次并再次请求蓝牙权限。
        """
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()
        let runner = SystemProcessRunner()

        let installedBinaries = [paths.binURL, paths.hooksBinaryURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !installedBinaries.isEmpty else {
            throw CLIError("还没装，请先运行 signal-light install。", exitCode: .noInput)
        }

        let unstableBinaries = installedBinaries.filter { binary in
            if case .unstable = CodeSigning.state(of: binary, processRunner: runner) {
                return true
            }
            return false
        }
        guard !unstableBinaries.isEmpty else {
            terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("程序已使用稳定签名，无需处理。"))")
            return
        }

        terminal.progress("\(terminal.emoji(CLIGlyph.signing))配置固定签名…")

        let keychain = paths.home.appendingPathComponent("Library/Keychains/login.keychain-db")
        let storeDirectory = paths.cliRootDir.appendingPathComponent("dev-signing", isDirectory: true)

        if !SigningIdentity.isAvailable(processRunner: runner) {
            let certURL = try SigningIdentity.importIdentity(
                storeDirectory: storeDirectory,
                keychain: keychain,
                processRunner: runner
            )
            terminal.progress("    • 创建签名身份 → \(PathText.abbreviated(certURL, relativeTo: paths.home))")

            terminal.progress("    • 信任证书（macOS 请求一次授权，请点「允许」）")
            guard try SigningIdentity.trustIdentity(certURL: certURL, keychain: keychain, processRunner: runner) else {
                throw CLIError(
                    """
                    信任授权未完成，无法使用固定签名。手动执行这条命令后重试：
                      \(SigningIdentity.manualTrustCommand(certURL: certURL, keychain: keychain))
                    """,
                    exitCode: .noInput
                )
            }
        }

        for binary in unstableBinaries {
            try SigningIdentity.sign(binary, processRunner: runner)
            terminal.progress("    • 签名 → \(PathText.abbreviated(binary, relativeTo: paths.home))")
        }
        terminal.out("\(terminal.emoji(CLIGlyph.success))\(terminal.success("固定签名已配置。"))")

        // Re-signing changed the running binary's code identity, so the
        // daemon must restart to pick it up — which is also the moment TCC
        // asks for Bluetooth permission again.
        let control = LaunchAgentControl(paths: paths)
        do {
            if try control.restartIfRunning() {
                terminal.out("")
                terminal.out("\(terminal.emoji(CLIGlyph.warning))\(terminal.warning("后台服务已重启，macOS 会请求蓝牙权限，点「允许」。"))")
            }
        } catch {
            terminal.warn("后台服务重启失败：\(error)。可运行 signal-light service restart 重试。")
        }
    }
}
