import Darwin
import Foundation

/// The hook binary's one-shot client: connect, write one JSON line, wait
/// briefly for the ack.
///
/// Hooks sit in the agent's hot path, which is why every failure is silent
/// and bounded — "the light didn't update" is always acceptable, a stalled
/// agent never is.
public enum HookSocketClient {
    @discardableResult
    public static func send(_ event: HookEvent, to socketURL: URL, timeout: TimeInterval = 2) -> Bool {
        guard let payload = try? JSONEncoder().encode(event),
              var address = UnixSocket.address(for: socketURL.path) else {
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking connect plus a poll deadline: even a listener with a
        // full backlog can't stall the agent.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let connected = UnixSocket.withSockaddr(&address, { connect(fd, $0, $1) })
        if connected != 0 {
            guard errno == EINPROGRESS else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return false }
        }

        let message = payload + Data([0x0A])
        let written = message.withUnsafeBytes { write(fd, $0.baseAddress, message.count) }
        guard written == message.count else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return false }

        var ack = [UInt8](repeating: 0, count: 64)
        return read(fd, &ack, ack.count) > 0
    }
}
