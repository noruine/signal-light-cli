import Foundation
import Testing

@testable import SignalLightKit

@Suite("Hook socket")
struct HookSocketTests {
    @Test("An event reaches the registry over the socket and is acknowledged")
    func roundTrip() async throws {
        try await withSocketPath { socketURL in
            let registry = SessionRegistry()
            let listener = HookListener(socketURL: socketURL, registry: registry) { _ in }
            try await listener.start()
            defer { Task { await listener.stop() } }

            let sent = HookSocketClient.send(
                HookEvent(source: .claude, kind: .userPromptSubmit, sessionID: "s1"),
                to: socketURL
            )

            #expect(sent)
            #expect(await registry.bucket() == .running)
        }
    }

    @Test("A missing daemon is a silent, bounded failure")
    func missingDaemon() {
        let missing = URL(filePath: "/tmp/signal-light-absent-\(UUID().uuidString).sock")
        let sent = HookSocketClient.send(
            HookEvent(source: .codex, kind: .stop, sessionID: "s1"),
            to: missing,
            timeout: 1
        )
        #expect(sent == false)
    }

    @Test("Garbage on the socket never reaches the registry")
    func garbageIsIgnored() async throws {
        try await withSocketPath { socketURL in
            let registry = SessionRegistry()
            let listener = HookListener(socketURL: socketURL, registry: registry) { _ in }
            try await listener.start()
            defer { Task { await listener.stop() } }

            try sendRaw(Data("not json".utf8), to: socketURL)
            #expect(await registry.bucket() == .idle)
        }
    }

    /// Runs `body` with a throwaway socket path under a short `/tmp`
    /// directory and removes the directory afterwards — cases used to leave
    /// one behind per run, piling up in /tmp across runs. The base stays
    /// deliberately short: `sun_path` tops out at 104 bytes and the system
    /// temp directory alone eats half of that.
    private func withSocketPath<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = URL(filePath: "/tmp/sl-test-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory.appending(path: "b.sock"))
    }

    private func sendRaw(_ payload: Data, to socketURL: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/nc")
        process.arguments = ["-U", socketURL.path]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(payload)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
