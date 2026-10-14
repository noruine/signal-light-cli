import Foundation
import SignalLightKit

/// Detects whether a Unix-domain socket path currently has an active
/// listener, via a real connection attempt. This is what lets `run` refuse
/// to replace a socket another daemon is using, and tells `uninstall` whether
/// a leftover socket file is safe to delete.
public enum SocketProbe {
    public static func isActive(_ url: URL) -> Bool {
        UnixSocket.isActive(path: url.path)
    }
}
