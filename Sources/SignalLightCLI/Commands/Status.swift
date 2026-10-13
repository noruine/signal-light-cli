import ArgumentParser
import Darwin
import Foundation
import SignalLightKit

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "查看后台服务与信号灯的当前状态。")

    @OptionGroup var globals: GlobalOptions

    @Flag(help: "输出 JSON 格式（不带颜色和 emoji，方便脚本解析）。")
    var json: Bool = false

    func run() async throws {
        let snapshot = StatusSnapshot.current(paths: .current())
        let terminal = globals.makeTerminal()

        if json {
            try snapshot.printJSON()
            return
        }

        snapshot.printHumanReadable(terminal: terminal)
    }
}

/// Everything `status` reads to describe the current state — factored out so
/// the interactive menu's header can show the same summary without
/// re-deriving it (and risking the two views drifting apart).
struct StatusSnapshot {
    let paths: SignalLightDaemonPaths
    let jobInfo: LaunchAgentControl.JobInfo
    /// nil ⇒ no launchd service registered yet (never `service start`ed).
    let runAtLoad: Bool?
    let toolInstalled: Bool
    let state: SignalLightDaemonState?
    /// Whether `state` was written by a daemon that is still running. The
    /// daemon never writes a final "disconnected" snapshot on its way out, so
    /// a snapshot whose writer is gone describes the *last* run — reporting it
    /// as the current BLE/bucket state would be a lie.
    let stateIsLive: Bool
    /// The paired device's name from the device store; nil ⇒ not paired.
    let pairedDeviceName: String?
    /// The name shown for the connection: the live one when connected, else
    /// the paired name.
    let deviceName: String?

    /// Whether the service's process is actually alive. `isLoaded` alone can't
    /// answer that: a job that exited cleanly (killed with SIGTERM outside
    /// `service stop`) stays registered in launchd with no process, and
    /// reporting that as "运行中" would claim the light is being driven when
    /// nothing is running.
    var serviceIsRunning: Bool {
        jobInfo.isLoaded && jobInfo.pid != nil
    }

    static func current(paths: SignalLightDaemonPaths) -> StatusSnapshot {
        let control = LaunchAgentControl(paths: paths)
        let jobInfo = control.jobInfo()
        let runAtLoad = control.currentRunAtLoad()
        let toolInstalled = FileManager.default.fileExists(atPath: paths.binURL.path)
        let state = try? SignalLightDaemonStateStore.load(from: paths.stateJSONURL)
        let pairedDeviceName = (try? SignalLightDeviceStore.load(from: paths.deviceJSONURL))?.name
        let stateIsLive = isStateLive(state, jobInfo: jobInfo)
        let deviceName = stateIsLive ? (state?.deviceName ?? pairedDeviceName) : pairedDeviceName

        return StatusSnapshot(
            paths: paths,
            jobInfo: jobInfo,
            runAtLoad: runAtLoad,
            toolInstalled: toolInstalled,
            state: state,
            stateIsLive: stateIsLive,
            pairedDeviceName: pairedDeviceName,
            deviceName: deviceName
        )
    }

    /// Live ⇒ the snapshot's writer is still alive. Files written before the
    /// `pid` field existed fall back to "the launchd job is loaded", the best
    /// signal an old snapshot can offer.
    private static func isStateLive(_ state: SignalLightDaemonState?, jobInfo: LaunchAgentControl.JobInfo) -> Bool {
        guard let state else { return false }
        guard let pid = state.pid else { return jobInfo.isLoaded }
        return isProcessAlive(pid)
    }

    private static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        // A live process owned by another user answers EPERM, not success.
        return errno == EPERM
    }

    func printHumanReadable(terminal: Terminal) {
        terminal.out("\(terminal.emoji(CLIGlyph.trafficLight))信号灯")

        terminal.out("    服务      \(terminal.statusDot(serviceIsRunning)) \(serviceDescription)")

        terminal.out("    设备      \(terminal.statusDot(pairedDeviceName != nil)) \(deviceDescription)")

        // Only a snapshot with a live writer describes right now; a leftover
        // file keeps its stale fields out of the report entirely.
        if stateIsLive {
            terminal.out("    蓝牙      \(terminal.statusDot(state?.ble == .connected)) \(bleDescription)")
            if let bucket = state?.currentBucket {
                terminal.out("    当前状态  \(SignalLightBucketDisplay.name(forRaw: bucket))")
            }
        } else {
            terminal.out("    蓝牙      —  \(state == nil ? "还没有状态记录" : "服务未运行，看不到实时状态")")
        }

        terminal.out("    日志      \(PathText.abbreviated(paths.logURL))")
    }

    /// One compact line for the interactive menu's header: service state, the
    /// bluetooth link, and which bucket the light is showing right now. The
    /// log path and PIDs belong to `status`, not a menu header.
    func printMenuHeader(terminal: Terminal) {
        var segments = ["服务 \(terminal.statusDot(serviceIsRunning)) \(menuServiceDescription)"]
        if stateIsLive {
            segments.append("蓝牙 \(terminal.statusDot(state?.ble == .connected)) \(menuBluetoothDescription)")
            segments.append("当前 \(menuBucketDescription)")
        }
        terminal.out("    " + segments.joined(separator: "   "))
    }

    var menuServiceDescription: String {
        guard jobInfo.isLoaded else {
            return toolInstalled ? "已停止" : "未安装"
        }
        guard jobInfo.pid != nil else {
            return "已登记，未运行"
        }
        switch runAtLoad {
        case true?: return "运行中 · 自启开"
        case false?: return "运行中 · 自启关"
        case nil: return "运行中"
        }
    }

    private var menuBluetoothDescription: String {
        switch state?.ble {
        case .connected:
            return state?.deviceName ?? deviceName ?? "已连接"
        case .connecting:
            return "连接中…"
        case .scanning:
            return "扫描中…"
        case .poweredOff:
            return "蓝牙已关闭"
        case .unauthorized:
            return "未授权"
        case .disconnected, .none:
            return "未连接"
        }
    }

    private var menuBucketDescription: String {
        guard let bucket = state?.currentBucket,
              let parsed = SignalLightBucket(rawValue: bucket) else {
            return "—"
        }
        return "\(SignalLightBucketDisplay.emoji(parsed))\(SignalLightBucketDisplay.name(parsed))"
    }

    /// Abbreviates against the home `SignalLightDaemonPaths` resolves (which
    /// honors `$HOME`), so printed paths match the ones scripts use.
    private var serviceDescription: String {
        if let pid = jobInfo.pid {
            return "运行中 (PID \(pid)，开机自启：\(runAtLoad == true ? "是" : "否"))"
        }
        // Both not-running states (registered with a dead process, and
        // registered-but-stopped) want the same next step, and the same
        // wording: "已登记，未运行 — 运行 …" stacked three 运行s in one line.
        let stopped = "已登记，未运行 — 运行 signal-light service start"
        if jobInfo.isLoaded {
            // Registered with launchd, but no process behind it: it exited
            // without being booted out, so it is not driving anything.
            return stopped
        }
        if !toolInstalled {
            return "未安装 — 在仓库里运行 make install"
        }
        if runAtLoad == nil {
            return "未启动 — 运行 signal-light service start"
        }
        // The plist is on disk, but the service was stopped with `service stop`.
        return stopped
    }

    private var deviceDescription: String {
        if let pairedDeviceName {
            return "已配对 “\(pairedDeviceName)”"
        }
        return toolInstalled ? "未配对 — 运行 signal-light pair" : "未配对"
    }

    /// Only called while `stateIsLive`, so the "no daemon" cases the old
    /// version had to spell out (`服务未运行`) no longer exist here.
    private var bleDescription: String {
        switch state?.ble {
        case .connected:
            // The device's name lives on the 设备 line; restating it here would
            // just duplicate the same words twice in one short block.
            return "已连接"
        case .connecting:
            return "正在连接…"
        case .scanning:
            return "正在扫描…"
        case .poweredOff:
            return "蓝牙已关闭"
        case .unauthorized:
            return "蓝牙未授权，请在 系统设置 → 隐私与安全性 → 蓝牙 里允许"
        case .disconnected, .none:
            return "未连接，正在重试"
        }
    }

    func printJSON() throws {
        struct Output: Encodable {
            let serviceRegistered: Bool
            let serviceLoaded: Bool
            let servicePID: Int?
            let runAtLoad: Bool?
            let toolInstalled: Bool
            let paired: Bool
            let pairedDeviceName: String?
            /// `"unknown"` while no live daemon is writing state.json — the
            /// only honest value once the last writer is gone.
            let ble: String
            let deviceName: String?
            let currentBucket: String?
            /// Whether the `ble`/`currentBucket`/`stateUpdatedAt` fields come
            /// from a daemon that is still running.
            let stateLive: Bool
            let stateUpdatedAt: String?
            let logPath: String
        }

        let output = Output(
            serviceRegistered: runAtLoad != nil,
            serviceLoaded: jobInfo.isLoaded,
            servicePID: jobInfo.pid,
            runAtLoad: runAtLoad,
            toolInstalled: toolInstalled,
            paired: pairedDeviceName != nil,
            pairedDeviceName: pairedDeviceName,
            ble: stateIsLive ? (state?.ble.rawValue ?? SignalLightDaemonState.BLE.disconnected.rawValue) : "unknown",
            deviceName: deviceName,
            currentBucket: stateIsLive ? state?.currentBucket : nil,
            stateLive: stateIsLive,
            stateUpdatedAt: state.map { ISO8601DateFormatter().string(from: $0.updatedAt) },
            logPath: paths.logURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(data: try encoder.encode(output), encoding: .utf8) ?? "{}")
    }
}
