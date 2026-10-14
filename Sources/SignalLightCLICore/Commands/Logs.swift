import ArgumentParser
import Foundation
import SignalLightKit

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "查看信号灯服务日志。")

    @OptionGroup var globals: GlobalOptions

    @Option(name: .shortAndLong, help: "显示末尾多少行。")
    var lines: Int = 50

    @Flag(name: .shortAndLong, help: "持续输出新增日志内容（类似 tail -f）。")
    var follow: Bool = false

    func run() async throws {
        let terminal = globals.makeTerminal()
        let paths = SignalLightDaemonPaths.current()

        // `suffix(_:)` traps on a negative length — a typo like
        // `--lines=-5` must be a clean usage error, not a crash.
        guard lines >= 0 else {
            throw CLIError("--lines 不能是负数。", exitCode: .usage)
        }

        guard FileManager.default.fileExists(atPath: paths.logURL.path) else {
            // A service that never started is a normal state, not a failure
            // of this command: say so plainly and point at where the log
            // will be.
            terminal.out("还没有日志：服务应该从未启动过。启动服务后，日志写在 \(displayPath(paths.logURL))。")
            return
        }

        terminal.progress("\(terminal.emoji(CLIGlyph.logs))\(displayPath(paths.logURL))（末尾 \(lines) 行）")
        try printTail(of: paths.logURL, lineCount: lines)

        guard follow else { return }
        try await followFile(paths.logURL)
    }

    /// Abbreviates against the home `SignalLightDaemonPaths` resolves (which
    /// honors `$HOME`), matching the paths the rest of the CLI prints.
    private func displayPath(_ url: URL) -> String {
        let home = SignalLightDaemonPaths.current().home.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func printTail(of url: URL, lineCount: Int) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        var allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
        // A file ending in "\n" (every file this CLI writes) splits into a
        // trailing empty element. Counting it as a line would make
        // `--lines 2` print only one line of content.
        if allLines.last?.isEmpty == true {
            allLines.removeLast()
        }
        for line in allLines.suffix(lineCount) {
            print(line)
        }
    }

    private func followFile(_ url: URL) async throws {
        var lastSignature = fileSignature(url)

        while true {
            try await Task.sleep(nanoseconds: 500_000_000)

            let signature = fileSignature(url)
            guard signature != lastSignature else { continue }

            // `RestrainedLog` rewrites the file both at daemon startup and when
            // it hits its size cap — and the capped rewrite (`maxBytes / 2`)
            // lands on exactly the same size every time. A size that shrank OR
            // a same-size rewrite means the front of the file is gone, so
            // re-read from the top instead of treating the region at the old
            // offset as an append.
            let wasRewritten = signature.size < lastSignature.size
                || (signature.size == lastSignature.size && signature.modified != lastSignature.modified)
            appendNewContent(of: url, from: wasRewritten ? 0 : lastSignature.size)
            lastSignature = signature
        }
    }

    private func appendNewContent(of url: URL, from offset: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: offset)
        let newData = handle.readDataToEndOfFile()
        if let text = String(data: newData, encoding: .utf8) {
            print(text, terminator: "")
        }
    }

    /// Size plus modification date: size alone can't tell an append from a
    /// rewrite that ended at the same length (see `followFile`).
    private struct FileSignature: Equatable {
        let size: UInt64
        let modified: Date?
    }

    private func fileSignature(_ url: URL) -> FileSignature {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return FileSignature(size: 0, modified: nil)
        }
        return FileSignature(
            size: attributes[.size] as? UInt64 ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
    }
}
