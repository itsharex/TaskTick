import Foundation

/// Streams a single running script's stdout/stderr to a plain-text log file
/// under `~/Library/Logs/TaskTick/`. Designed for the manual-script /
/// dev-server scenario where the user wants `tail -f` from a terminal or
/// drag the file into Console.app.
///
/// One file per task, truncated on each new run — the SwiftData
/// `ExecutionLog` table is the system of record for execution history; this
/// file is just the latest run's live tail. Failure to open or write is
/// silently swallowed: logging breakage must never take down a task run.
final class LogFileWriter: @unchecked Sendable {
    let fileURL: URL
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "com.lifedever.tasktick.logwriter")
    /// Holds the tail of a chunk that might be the start of an ANSI escape
    /// sequence split across pipe reads. Without this, a chunk ending in
    /// `\x1B[0;32` followed by `m\nlog text\n` would have the head ESC
    /// orphaned (unstrippable) and the tail's `m` stranded as visible junk.
    private var pendingEscape = ""

    init?(taskName: String) {
        guard let dir = Self.logsDirectory() else { return nil }
        let url = dir.appendingPathComponent("\(Self.slug(for: taskName)).log")
        let fm = FileManager.default
        // Truncate any previous run's content. createFile returns false if
        // the path is unwritable (permissions, full disk) — bail out so the
        // task still runs, just without file logging.
        guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.fileURL = url
        self.handle = handle
    }

    /// Append a chunk. Safe to call from any thread; serialized through an
    /// internal queue so concurrent stdout/stderr handlers don't interleave
    /// inside a single write() syscall.
    ///
    /// ANSI escape codes are stripped before writing — the file is meant to
    /// be opened in Console.app or `cat`, neither of which renders escape
    /// sequences. Terminal users running `tail -f` lose color, which is
    /// the lesser evil. Sequences split across pipe reads (rare but real)
    /// are buffered via `pendingEscape`.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let raw = String(decoding: data, as: UTF8.self)
            let combined = self.pendingEscape + raw
            let (safe, pending) = Self.splitOnIncompleteEscape(combined)
            self.pendingEscape = pending
            let cleaned = stripANSI(safe)
            guard !cleaned.isEmpty else { return }
            try? self.handle?.write(contentsOf: Data(cleaned.utf8))
        }
    }

    /// Hold back any trailing partial ANSI sequence so the next chunk can
    /// reassemble and strip it. Recognizes the three forms TaskTick's
    /// `stripANSI()` regex covers: CSI (`ESC [ … letter`), OSC
    /// (`ESC ] … BEL`), and the 3-byte charset selectors (`ESC ( X` /
    /// `ESC ) X`). Anything else falls through as "complete" — those
    /// sequences are rare and would just appear inline as plain text.
    private static func splitOnIncompleteEscape(_ text: String) -> (safe: String, pending: String) {
        guard let escIdx = text.lastIndex(of: "\u{1B}") else {
            return (text, "")
        }
        let afterEsc = text[text.index(after: escIdx)...]
        let head = String(text[..<escIdx])
        let tail = String(text[escIdx...])

        guard let firstByte = afterEsc.first else {
            // Bare ESC at end — definitely incomplete.
            return (head, tail)
        }

        switch firstByte {
        case "[":
            // CSI: complete iff we've seen the final letter.
            if afterEsc.dropFirst().contains(where: { $0.isASCII && $0.isLetter }) {
                return (text, "")
            }
            return (head, tail)
        case "]":
            // OSC: terminated by BEL (\x07).
            if afterEsc.contains("\u{07}") {
                return (text, "")
            }
            return (head, tail)
        case "(", ")":
            // Charset selector: ESC + paren + 1 byte.
            if afterEsc.count >= 2 {
                return (text, "")
            }
            return (head, tail)
        default:
            return (text, "")
        }
    }

    /// Idempotent — closes the underlying handle. Subsequent appends are
    /// no-ops. The on-disk file is left in place for the user to inspect.
    func close() {
        queue.async { [weak self] in
            try? self?.handle?.close()
            self?.handle = nil
        }
    }

    deinit {
        // Defensive: `close()` should have been called explicitly when the
        // process ended, but if the executor was deallocated mid-flight we
        // still want the fd released so the file isn't held open forever.
        try? handle?.close()
    }

    // MARK: - Static helpers

    /// `~/Library/Logs/TaskTick/`. Returns nil only if the user's Library
    /// directory itself can't be located or created — extremely rare.
    static func logsDirectory() -> URL? {
        let fm = FileManager.default
        guard let lib = try? fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = lib.appendingPathComponent("Logs/TaskTick", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Map a user-visible task name to a filesystem-safe filename stem.
    /// Keeps CJK and most printable characters — only neutralizes the few
    /// that confuse macOS (`/`, `:`, `\`) plus control characters. Falls
    /// back to "task" when sanitization leaves an empty string.
    static func slug(for taskName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
        var result = ""
        for scalar in taskName.unicodeScalars {
            result.unicodeScalars.append(forbidden.contains(scalar) ? "-" : scalar)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "task" : trimmed
    }

    /// URL of a task's log file (without checking existence). Used by views
    /// that want to surface the path even when no run has happened yet.
    static func fileURL(for taskName: String) -> URL? {
        guard let dir = logsDirectory() else { return nil }
        return dir.appendingPathComponent("\(slug(for: taskName)).log")
    }

    /// Best-effort cleanup when a task is deleted. Logs leftover from
    /// renames remain — those are handled by a separate periodic sweep
    /// (not yet implemented; orphans cost only a few MB).
    static func deleteFile(for taskName: String) {
        guard let url = fileURL(for: taskName) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
