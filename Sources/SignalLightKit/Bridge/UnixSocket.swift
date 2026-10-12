import Darwin
import Foundation

/// POSIX plumbing for the hook socket.
///
/// Network.framework's `NWListener` refuses Unix-domain binds on this SDK
/// (EINVAL), and this socket only needs to be boring: one read, one ack,
/// close.
public enum UnixSocket {
    /// Socket paths live in a fixed-size array; a longer path is silently
    /// truncated by the kernel, so refuse it up front.
    public static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// Calls `body` with the socket address as the C API expects it. The
    /// pointer is only valid inside the closure — that is the point.
    public static func withSockaddr<T>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    public static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
