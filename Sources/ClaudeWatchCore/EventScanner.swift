import Foundation

/// Discovers transcript files under ~/.claude/projects and extracts command events.
/// Supports an incremental mode: it remembers a byte offset per file and only parses
/// the newly-appended, complete lines on each poll.
public final class EventScanner {

    public let source: TranscriptSource
    public let root: URL
    private var codexContexts: [String: CodexTranscriptParser.FileContext] = [:]

    public init(source: TranscriptSource = .claude, root: URL? = nil) {
        self.source = source
        self.root = root ?? source.defaultRoot
    }

    /// All `*.jsonl` transcripts (top-level sessions and nested subagent/workflow runs).
    public func discoverFiles() -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if source == .codex && root.path.contains("/.codex") {
                let path = url.path
                guard path.contains("/.codex/sessions/") || path.contains("/.codex/archived_sessions/") else {
                    continue
                }
            }
            files.append(url)
        }
        return files
    }

    /// Full one-shot scan of every transcript. Used by `--dump` and as the implicit
    /// first poll (when all offsets start at 0).
    public func fullScan() -> [CommandEvent] {
        reset()
        var offsets: [String: UInt64] = [:]
        return parseDelta(offsets: &offsets)
    }

    public func reset() {
        codexContexts.removeAll()
    }

    /// Stream every newly-appended, complete line since the last call, invoking `onLine`
    /// with the line and its file path. Mutates `offsets` in place. Newly-discovered files
    /// are read from the beginning; truncated/rotated files reset; vanished files are pruned.
    /// `onLine` is called synchronously and must not escape.
    public func scanDelta(offsets: inout [String: UInt64], onLine: (Substring, String) -> Void) {
        let files = discoverFiles()
        for url in files {
            let path = url.path
            let size = fileSize(url)
            let previous = offsets[path] ?? 0

            if size == previous { continue }            // unchanged
            let start: UInt64 = size < previous ? 0 : previous   // shrunk → re-read

            guard let (data, newOffset) = readDelta(url, from: start) else {
                // No complete line available yet; remember where we are so we don't
                // re-read the partial bytes next tick.
                offsets[path] = start
                continue
            }
            offsets[path] = newOffset

            if start == 0 && source == .codex {
                codexContexts[path] = CodexTranscriptParser.FileContext()
            }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onLine(line, path)
            }
        }

        // Reclaim offset entries for files that have been deleted or rotated away, so the
        // map can't grow without bound over a long-running session.
        if offsets.count > files.count {
            let live = Set(files.map { $0.path })
            offsets = offsets.filter { live.contains($0.key) }
            codexContexts = codexContexts.filter { live.contains($0.key) }
        }
    }

    /// Parse everything appended since the last call into command events.
    public func parseDelta(offsets: inout [String: UInt64]) -> [CommandEvent] {
        var results: [CommandEvent] = []
        scanDelta(offsets: &offsets) { line, path in
            results.append(contentsOf: events(fromLine: line, transcriptPath: path))
        }
        return results
    }

    public func events(fromLine line: Substring, transcriptPath path: String) -> [CommandEvent] {
        switch source {
        case .claude:
            return TranscriptParser.events(fromLine: line, transcriptPath: path)
        case .codex:
            var context = codexContexts[path] ?? CodexTranscriptParser.FileContext()
            let events = CodexTranscriptParser.events(fromLine: line, transcriptPath: path, context: &context)
            codexContexts[path] = context
            return events
        }
    }

    // MARK: - Low level

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return 0 }
        return number.uint64Value
    }

    /// Reads bytes `[start, EOF)` but only returns up to the last newline, so we never
    /// hand a half-written JSON line to the parser. Returns the consumed data and the
    /// new offset (just past the last newline).
    private func readDelta(_ url: URL, from start: UInt64) -> (Data, UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return nil   // a line is still being written; wait for the newline
        }
        let consume = data.subdata(in: data.startIndex..<(lastNewline + 1))
        return (consume, start + UInt64(consume.count))
    }
}
