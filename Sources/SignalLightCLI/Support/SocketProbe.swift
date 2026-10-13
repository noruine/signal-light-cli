import Darwin
import Foundation

/// Detects whether a Unix-domain socket path currently has an active
/// listener, via a real non-blocking connect attempt — the same technique
/// `signal-light-bridge.py` uses. This is what lets `run` refuse to start
/// rather than silently stealing the socket out from under another running
/// daemon, or
/// another bridge process: `HookListener.start` unconditionally
/// unlinks the path before binding, so starting blind would silently hijack
/// whatever is already listening there. It's also what tells `uninstall`
/// whether a leftover socket file is safe to delete.
public enum SocketProbe {
    public static func isActive(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor != -1 else {
            return false
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let path = url.path
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return connectResult != -1
    }
}
