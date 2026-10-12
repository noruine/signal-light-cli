import ArgumentParser
import CoreBluetooth
import Foundation
import SignalLightKit

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "诊断常见问题：设备配对、签名稳定性、后台服务、蓝牙授权。"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(help: "输出 JSON 格式（不带颜色，方便脚本解析）。")
    var json: Bool = false

    func run() async throws {
        let paths = SignalLightDaemonPaths.current()
        let control = LaunchAgentControl(paths: paths)
        let processRunner = SystemProcessRunner()

        let checks = [
            checkPairing(paths: paths),
            checkSigning(paths: paths, processRunner: processRunner),
            checkServiceAndSocket(paths: paths, control: control),
            checkBluetoothAuthorization(),
        ]

        if json {
            try printJSON(checks)
        } else {
            printHumanReadable(checks)
        }

        guard !checks.contains(where: { $0.status == .fail }) else {
            throw CLIError("有问题要处理，看上面对应那几条。", exitCode: .software)
        }
    }

    // MARK: - Checks

    private func checkPairing(paths: SignalLightDaemonPaths) -> DoctorCheck {
        guard let device = try? SignalLightDeviceStore.load(from: paths.deviceJSONURL) else {
            return DoctorCheck(status: .fail, title: "设备配对", detail: "还没配对，请运行 signal-light pair。")
        }
        guard UUID(uuidString: device.identifier) != nil else {
            return DoctorCheck(status: .fail, title: "设备配对", detail: "配对信息已损坏，请重新配对：signal-light pair")
        }
        return DoctorCheck(status: .ok, title: "设备配对", detail: "已配对 “\(device.name)”。")
    }

    /// Ad-hoc signatures rotate their cdhash on every rebuild, which quietly
    /// invalidates any Bluetooth permission grant TCC recorded for the
    /// previous build — the same failure mode documented for the dev app's
    /// Accessibility permission (see `scripts/setup-dev-signing.sh`).
    private func checkSigning(paths: SignalLightDaemonPaths, processRunner: ProcessRunning) -> DoctorCheck {
        guard FileManager.default.fileExists(atPath: paths.binURL.path) else {
            return DoctorCheck(status: .warn, title: "签名稳定性", detail: "还没装，跳过。")
        }

        guard let result = try? processRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", paths.binURL.path]
        ) else {
            return DoctorCheck(status: .warn, title: "签名稳定性", detail: "codesign 跑不起来，跳过。")
        }

        let output = result.stdout + result.stderr
        if result.exitCode != 0 {
            return DoctorCheck(
                status: .warn,
                title: "签名稳定性",
                detail: "没签名；重新编译后可能要重新授权蓝牙。建议签一下：codesign --sign \"Signal Light Dev Local\" \(paths.binURL.path)"
            )
        }
        if output.localizedCaseInsensitiveContains("adhoc") {
            return DoctorCheck(
                status: .warn,
                title: "签名稳定性",
                detail: "是临时（ad-hoc）签名，每次重新构建都换身份，蓝牙权限可能反复失效。换个固定签名吧。"
            )
        }
        return DoctorCheck(status: .ok, title: "签名稳定性", detail: "使用稳定签名身份。")
    }

    private func checkServiceAndSocket(paths: SignalLightDaemonPaths, control: LaunchAgentControl) -> DoctorCheck {
        guard FileManager.default.fileExists(atPath: paths.launchAgentPlistURL.path) else {
            // No plist yet means the launchd service was never registered.
            // Distinguish "the tool itself isn't installed" from "installed
            // but never started" — after the install/service split these are
            // two different next steps.
            if FileManager.default.fileExists(atPath: paths.binURL.path) {
                return DoctorCheck(status: .warn, title: "后台服务", detail: "还没启动，请运行 signal-light service start。")
            }
            return DoctorCheck(status: .warn, title: "后台服务", detail: "还没装，请运行 signal-light install。")
        }

        let jobInfo = control.jobInfo()
        let socketActive = paths.ownedSockets.contains(where: SocketProbe.isActive)

        // Registered is not running: a job that exited cleanly (a bare
        // SIGTERM, say) stays loaded with no process behind it — blaming the
        // socket or Bluetooth here would hide the real next step.
        if jobInfo.isLoaded, jobInfo.pid == nil {
            return DoctorCheck(
                status: .warn,
                title: "后台服务",
                detail: "launchd 里登记着，但进程没起来；请运行 signal-light service start。"
            )
        }

        if jobInfo.isLoaded {
            guard socketActive else {
                return DoctorCheck(
                    status: .warn,
                    title: "后台服务",
                    detail: "launchd 显示正在运行，但 socket 还没就绪：可能刚启动，或蓝牙未就绪。运行 signal-light status 查看详情。"
                )
            }
            let pidText = jobInfo.pid.map { "（PID \($0)）" } ?? ""
            return DoctorCheck(status: .ok, title: "后台服务", detail: "运行中\(pidText)，bridge socket 也在。")
        }

        guard socketActive else {
            return DoctorCheck(status: .warn, title: "后台服务", detail: "登记过但没启动；请运行 signal-light service start。")
        }
        return DoctorCheck(
            status: .fail,
            title: "后台服务",
            detail: "服务未运行，但 socket 被其他进程占用（可能是 App 或另一个桥接程序）；两边不能同时驱动一盏灯。"
        )
    }

    /// `CBManager.authorization` reads the system-recorded authorization
    /// state directly, without needing to instantiate a `CBCentralManager`
    /// and wait for a delegate callback.
    private func checkBluetoothAuthorization() -> DoctorCheck {
        switch CBManager.authorization {
        case .allowedAlways:
            return DoctorCheck(status: .ok, title: "蓝牙授权", detail: "已授权。")
        case .notDetermined:
            return DoctorCheck(status: .warn, title: "蓝牙授权", detail: "还没请求过权限，第一次启动服务时系统会弹窗。")
        case .denied:
            return DoctorCheck(status: .fail, title: "蓝牙授权", detail: "权限被拒。请在 系统设置 → 隐私与安全性 → 蓝牙 里允许。")
        case .restricted:
            return DoctorCheck(status: .fail, title: "蓝牙授权", detail: "权限被限制（比如家长控制），无法连接信号灯。")
        @unknown default:
            return DoctorCheck(status: .warn, title: "蓝牙授权", detail: "无法识别当前授权状态。")
        }
    }

    // MARK: - Output

    private func printHumanReadable(_ checks: [DoctorCheck]) {
        let terminal = globals.makeTerminal()
        terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))信号灯诊断")
        for check in checks {
            let label: String
            switch check.status {
            case .ok: label = terminal.success("正常")
            case .warn: label = terminal.warning("注意")
            case .fail: label = terminal.failure("异常")
            }
            terminal.out("\(label)  \(check.title)：\(check.detail)")
        }
    }

    private func printJSON(_ checks: [DoctorCheck]) throws {
        struct Output: Encodable {
            let status: String
            let title: String
            let detail: String
        }
        let items = checks.map { Output(status: $0.status.rawValue, title: $0.title, detail: $0.detail) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(data: try encoder.encode(items), encoding: .utf8) ?? "[]")
    }
}

private struct DoctorCheck {
    enum Status: String {
        case ok
        case warn
        case fail
    }

    let status: Status
    let title: String
    let detail: String
}
