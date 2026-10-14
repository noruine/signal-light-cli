import Darwin
import Foundation

/// Hosts the Unix socket that `agent-hooks` posts to.
///
/// One connection carries one JSON `HookEvent` and gets a one-line ack. The
/// daemon hears about session summaries through `onStateChange`, so there is no
/// second client and no loopback connection to babysit.
public actor HookListener {
    private let socketURL: URL
    private let registry: SessionRegistry
    private let onStateChange: @Sendable (SessionRegistry.Summary) -> Void
    private let acceptQueue = DispatchQueue(label: "app.signal-light.hook-listener")
    private let connectionQueue = DispatchQueue(label: "app.signal-light.hook-connections", attributes: .concurrent)
    private var refreshTask: Task<Void, Never>?
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var socketIdentity: (device: dev_t, inode: ino_t)?

    /// - Parameter onStateChange: Called after every event and refresh, even
    ///   when the resolved bucket stays the same.
    public init(
        socketURL: URL,
        registry: SessionRegistry,
        onStateChange: @escaping @Sendable (SessionRegistry.Summary) -> Void
    ) {
        self.socketURL = socketURL
        self.registry = registry
        self.onStateChange = onStateChange
    }

    /// Binds the socket and starts accepting, throwing if the bind fails so a
    /// busy port surfaces here instead of as a silently deaf daemon.
    public func start() throws {
        stop()

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try removeStaleSocket()

        guard var address = UnixSocket.address(for: socketURL.path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.currentError() }
        guard UnixSocket.withSockaddr(&address, { bind(fd, $0, $1) }) == 0 else {
            let error = UnixSocket.currentError()
            close(fd)
            throw error
        }
        guard listen(fd, 16) == 0 else {
            let error = UnixSocket.currentError()
            close(fd)
            throw error
        }

        var boundSocket = stat()
        guard lstat(socketURL.path, &boundSocket) == 0 else {
            let error = UnixSocket.currentError()
            close(fd)
            throw error
        }
        guard boundSocket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            close(fd)
            throw POSIXError(.EEXIST)
        }
        socketIdentity = (boundSocket.st_dev, boundSocket.st_ino)

        // Non-blocking accept: the read source tells us when work exists, and
        // the inner loop drains whatever piled up.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let registry = registry
        let onStateChange = onStateChange
        let connectionQueue = connectionQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }  // EAGAIN once the queue drains
                connectionQueue.async {
                    Task {
                        await Self.handle(client, registry: registry, onStateChange: onStateChange)
                    }
                }
            }
        }
        source.resume()

        let refreshRegistry = registry
        let refreshCallback = onStateChange
        refreshTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await refreshRegistry.refresh(onStateChange: refreshCallback)
            }
        }

        listenFD = fd
        acceptSource = source
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        removeOwnedSocket()
    }

    private func removeStaleSocket() throws {
        var current = stat()
        guard lstat(socketURL.path, &current) == 0 else {
            guard errno == ENOENT else { throw UnixSocket.currentError() }
            return
        }
        guard current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw POSIXError(.EEXIST)
        }
        guard !UnixSocket.isActive(path: socketURL.path) else {
            throw POSIXError(.EADDRINUSE)
        }
        guard unlink(socketURL.path) == 0 else { throw UnixSocket.currentError() }
    }

    private func removeOwnedSocket() {
        defer { socketIdentity = nil }
        guard let socketIdentity else { return }

        var current = stat()
        guard lstat(socketURL.path, &current) == 0,
              current.st_dev == socketIdentity.device,
              current.st_ino == socketIdentity.inode else {
            return
        }
        _ = unlink(socketURL.path)
    }

    private static func handle(
        _ fd: Int32,
        registry: SessionRegistry,
        onStateChange: @escaping @Sendable (SessionRegistry.Summary) -> Void
    ) async {
        defer { close(fd) }

        guard let payload = readMessage(fd),
              let event = try? JSONDecoder().decode(HookEvent.self, from: payload) else {
            return
        }

        // Apply before acking: the ack promises the event reached the state
        // machine, not merely the socket — clients may act on that.
        await registry.apply(event, onStateChange: onStateChange)

        let ack = Data(#"{"ok":true}"#.utf8) + Data([0x0A])
        _ = ack.withUnsafeBytes { write(fd, $0.baseAddress, ack.count) }
    }

    private static func readMessage(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 500) > 0 else { return data.isEmpty ? nil : data }

            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer[0..<count])

            if data.contains(0x0A) || data.count > 64 * 1024 {
                return data
            }
        }
    }
}
