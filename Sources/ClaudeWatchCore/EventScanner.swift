import Foundation

/// Discovers transcript files under ~/.claude/projects and extracts command events.
/// Supports an incremental mode: it remembers a byte offset per file and only parses
/// the newly-appended, complete lines on each poll.
public final class EventScanner {

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
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
            files.append(url)
        }
        return files
    }

    /// Full one-shot scan of every transcript. Used by `--dump` and as the implicit
    /// first poll (when all offsets start at 0).
    public func fullScan() -> [CommandEvent] {
        var offsets: [String: UInt64] = [:]
        return parseDelta(offsets: &offsets)
    }

    /// Parse everything appended since the last call. Mutates `offsets` in place.
    /// Newly-discovered files are read from the beginning; truncated/rotated files reset.
    public func parseDelta(offsets: inout [String: UInt64]) -> [CommandEvent] {
        var results: [CommandEvent] = []
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

            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                results.append(contentsOf: TranscriptParser.events(fromLine: line, transcriptPath: path))
            }
        }

        // Reclaim offset entries for files that have been deleted or rotated away, so the
        // map can't grow without bound over a long-running session.
        if offsets.count > files.count {
            let live = Set(files.map { $0.path })
            offsets = offsets.filter { live.contains($0.key) }
        }
        return results
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
