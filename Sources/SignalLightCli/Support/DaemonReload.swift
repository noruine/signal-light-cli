import Darwin
import SignalLightKit

/// Nudges a running daemon to re-read its settings file live, via SIGHUP —
/// so `config` changes take effect immediately without a restart (which would
/// briefly drop the BLE connection). A no-op when the daemon isn't running;
/// the on-disk settings are still authoritative for the next start.
enum DaemonReload {
    /// Returns `true` if a running daemon was signaled.
    @discardableResult
    static func reloadIfRunning(paths: SignalLightDaemonPaths) -> Bool {
        guard let pid = LaunchAgentControl(paths: paths).jobInfo().pid, pid > 0 else {
            return false
        }
        return kill(pid_t(pid), SIGHUP) == 0
    }
}
