import Foundation

enum MenuScreenBuffer {
    static func withAlternateBuffer<Result>(
        emit: (String) -> Void = { print($0, terminator: "") },
        operation: () async throws -> Result
    ) async rethrows -> Result {
        emit("\u{1B}[?1049h\u{1B}[?1007l")
        fflush(stdout)
        RawMode.noteAlternateScreen(true)
        defer {
            emit("\u{1B}[?1049l")
            fflush(stdout)
            RawMode.noteAlternateScreen(false)
        }
        return try await operation()
    }
}
