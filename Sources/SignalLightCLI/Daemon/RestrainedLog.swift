import Foundation

/// The single log file this daemon ever writes. Deliberately spare — it
/// records lifecycle events and errors, never per-hook chatter (the Python
/// bridge logs one line per hook event; this CLI explicitly does not, per
/// the "don't litter the disk" requirement). Truncated at daemon startup and
/// size-capped so a long-running install can't grow it unbounded.
public final class RestrainedLog: @unchecked Sendable {
    public enum Level: String, Sendable {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.signal-light.log")
    // Local wall-clock time, not UTC: this log is read by the person sitting
    // in front of the light, and "the timestamp is 8 hours off" is exactly
    // the kind of confusion a diagnostics log must not introduce.
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 64 KB, half of which survives a cap hit — enough for dozens of daemon
    /// runs of lifecycle lines (the only thing this log records), and small
    /// enough that nobody has to think about its disk cost.
    public init(url: URL, maxBytes: Int = 64 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Truncates the log for a fresh daemon run. MUST be called once, at the
    /// very top of `run`, before any other component starts logging —
    /// otherwise a previous run's tail would be mixed with this one's.
    public func startFresh() {
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public func log(_ level: Level, _ message: String) {
        // Written synchronously on purpose. The daemon exits via `exit(0)`
        // immediately after a shutdown signal, so an `async` write queued
        // behind that exit would be dropped — and the shutdown line is exactly
        // the one worth having. Entries are lifecycle events only (never
        // per-hook chatter), so blocking briefly here costs nothing.
        queue.sync { [self] in
            appendLine("\(formatter.string(from: .now)) [\(level.rawValue)] \(message)\n")
        }
    }

    private func appendLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }

        handle.seekToEndOfFile()
        let sizeBeforeWrite = handle.offsetInFile
        handle.write(data)

        if sizeBeforeWrite + UInt64(data.count) > UInt64(maxBytes) {
            truncateKeepingTail()
        }
    }

    /// Keeps the file bounded by discarding its older half rather than
    /// growing forever. The log is capped in the tens-of-KB range, so
    /// reading it fully back into memory here is cheap.
    private func truncateKeepingTail() {
        guard let contents = try? Data(contentsOf: url) else { return }
        let tail = contents.suffix(maxBytes / 2)
        try? tail.write(to: url, options: .atomic)
    }
}
