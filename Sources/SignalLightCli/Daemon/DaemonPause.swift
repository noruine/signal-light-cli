import SignalLightKit

/// Runs `body` while guaranteeing the background daemon isn't holding the
/// BLE connection, then restores whatever state the daemon was in before.
///
/// The ESP32 firmware accepts only one BLE connection at a time, so any
/// interactive command that opens its own `SignalLightBLESession`
/// (calibrate/firmware/rename) must first evict the daemon — otherwise it
/// would sit forever failing to connect to a device the daemon already owns.
/// This mirrors the Python `bridge-ctl.sh` guard, but improves on it: instead
/// of refusing to run and telling the user to stop the service by hand, it
/// pauses the service transparently and brings it back afterward.
enum DaemonPause {
    static func run<T>(
        terminal: Terminal,
        control: LaunchAgentControl,
        _ body: () async throws -> T
    ) async throws -> T {
        let wasLoaded = control.jobInfo().isLoaded

        if wasLoaded {
            terminal.progress("暂停后台服务，腾出蓝牙连接…")
            await control.bootoutAndWait()
            // The process is gone, but the firmware still needs a beat to
            // notice the BLE disconnect and free its single connection slot.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        do {
            let result = try await body()
            if wasLoaded {
                resumeDaemon(terminal: terminal, control: control)
            }
            return result
        } catch {
            if wasLoaded {
                resumeDaemon(terminal: terminal, control: control)
            }
            throw error
        }
    }

    /// A failed restore must be said out loud — silently leaving the light
    /// dead after a calibrate/preview would look like the command broke it.
    private static func resumeDaemon(terminal: Terminal, control: LaunchAgentControl) {
        terminal.progress("恢复后台服务…")
        do {
            try control.bootstrap()
        } catch {
            terminal.warn("后台服务未能恢复，请手动启动：signal-light service start（\(error)）")
        }
    }
}
