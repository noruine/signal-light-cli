import Darwin
import Foundation

/// Hosts the Unix socket that `signal-light-hooks` posts to.
///
/// One connection carries one JSON `HookEvent` and gets a one-line ack. The
/// daemon hears about bucket changes through `onBucketChange`, so there is no
/// second client and no loopback connection to babysit.
public actor HookListener {
    private let socketURL: URL
    private let registry: SessionRegistry
    private let onBucketChange: @Sendable (SignalLightBucket) -> Void
    private let acceptQueue = DispatchQueue(label: "app.signal-light.hook-listener")
    private let connectionQueue = DispatchQueue(label: "app.signal-light.hook-connections", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?

    /// - Parameter onBucketChange: Called for every bucket the registry lands
    ///   on, repeats included — the daemon decides whether the light changes.
    public init(
        socketURL: URL,
        registry: SessionRegistry,
        onBucketChange: @escaping @Sendable (SignalLightBucket) -> Void
    ) {
        self.socketURL = socketURL
        self.registry = registry
        self.onBucketChange = onBucketChange
    }

    /// Binds the socket and starts accepting, throwing if the bind fails so a
    /// busy port surfaces here instead of as a silently deaf daemon.
    public func start() throws {
        stop()

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A socket file left behind by a dead daemon would make the bind fail.
        try? FileManager.default.removeItem(at: socketURL)

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

        // Non-blocking accept: the read source tells us when work exists, and
        // the inner loop drains whatever piled up.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let registry = registry
        let onBucketChange = onBucketChange
        let connectionQueue = connectionQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }  // EAGAIN once the queue drains
                connectionQueue.async {
                    Self.handle(client, registry: registry, onBucketChange: onBucketChange)
                }
            }
        }
        source.resume()

        listenFD = fd
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private static func handle(
        _ fd: Int32,
        registry: SessionRegistry,
        onBucketChange: @escaping @Sendable (SignalLightBucket) -> Void
    ) {
        defer { close(fd) }

        guard let payload = readMessage(fd),
              let event = try? JSONDecoder().decode(HookEvent.self, from: payload) else {
            return
        }

        // Ack before the hook's patience runs out: a hook must never sit on a
        // socket timeout while its agent waits.
        let ack = Data(#"{"ok":true}"#.utf8) + Data([0x0A])
        _ = ack.withUnsafeBytes { write(fd, $0.baseAddress, ack.count) }

        Task {
            onBucketChange(await registry.apply(event))
        }
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
