import Foundation

/// A transcript on disk, as of one directory listing.
public struct TranscriptFile: Equatable {
    public let path: String
    public let size: UInt64
    public let modified: Date

    public init(path: String, size: UInt64, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// Discovers transcript files under ~/.claude/projects and extracts command events.
/// Supports an incremental mode: it remembers a byte offset per file and only parses
/// the newly-appended, complete lines on each poll.
public final class EventScanner {

    public let source: TranscriptSource
    public let root: URL
    private var codexContexts: [String: CodexTranscriptParser.FileContext] = [:]
    /// Files `skip` marked as read without reading them. If one grows later, its unread
    /// part still decides where the next line starts and what the Codex context is.
    private var skipped: Set<String> = []
    private let chunkSize: Int

    /// How much disk work has been done, for tests and measurements.
    struct Work: Equatable {
        var listings = 0            // directory walks
        var filesRead = 0           // transcripts opened to read new lines
        var bytesRead: UInt64 = 0
    }
    private(set) var work = Work()

    public convenience init(source: TranscriptSource = .claude, root: URL? = nil) {
        self.init(source: source, root: root, chunkSize: 1 << 20)
    }

    /// `chunkSize` is how much of a file is held at once; tests shrink it to cross chunk
    /// boundaries with small fixtures.
    init(source: TranscriptSource, root: URL?, chunkSize: Int) {
        self.source = source
        self.root = root ?? source.defaultRoot
        self.chunkSize = max(1, chunkSize)
    }

    // MARK: - Discovery

    /// The directories that can hold transcripts: what gets listed, and what is worth
    /// watching. A Codex home keeps them in `sessions/` and `archived_sessions/`; the rest
    /// of it (worktrees, plugins, caches: over 100,000 entries on a busy machine) is never
    /// walked.
    public var transcriptDirectories: [URL] {
        guard isCodexHome, root.lastPathComponent == ".codex" else { return [root] }
        return ["sessions", "archived_sessions"].map { root.appendingPathComponent($0, isDirectory: true) }
    }

    private var isCodexHome: Bool { source == .codex && root.path.contains("/.codex") }

    /// Whether `path` names a transcript, wherever it is.
    func isTranscript(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        guard isCodexHome else { return true }
        return path.contains("/.codex/sessions/") || path.contains("/.codex/archived_sessions/")
    }

    /// Walks the transcript directories, stopping as soon as `visit` returns false.
    private func walk(prefetching keys: [URLResourceKey], _ visit: (URL) -> Bool) {
        for directory in transcriptDirectories {
            guard let en = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in en where isTranscript(url.path) {
                if !visit(url) { return }
            }
        }
    }

    /// All `*.jsonl` transcripts (top-level sessions and nested subagent/workflow runs).
    public func discoverFiles() -> [URL] {
        var files: [URL] = []
        walk(prefetching: []) { files.append($0); return true }
        return files
    }

    /// Every transcript with its size and modification date, from the one directory walk
    /// (no per-file `stat`).
    public func listFiles() -> [TranscriptFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var files: [TranscriptFile] = []
        work.listings += 1
        walk(prefetching: Array(keys)) { url in
            let values = try? url.resourceValues(forKeys: keys)
            files.append(TranscriptFile(
                path: url.path,
                size: UInt64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            ))
            return true
        }
        return files
    }

    /// Whether at least one transcript exists. Stops at the first match, so it stays cheap
    /// however long the history is.
    public func hasFiles() -> Bool {
        var found = false
        walk(prefetching: []) { _ in found = true; return false }
        return found
    }

    /// The current state of one path a file watcher reported, or nil if it is gone or is
    /// not a transcript `listFiles` would return. `known` paths came from a listing already
    /// and skip that check.
    func file(atPath path: String, known: Bool) -> TranscriptFile? {
        guard known || isListable(path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        return TranscriptFile(
            path: path,
            size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attrs[.modificationDate] as? Date ?? .distantPast
        )
    }

    /// Mirrors the walk for a single path: inside a transcript directory, a transcript by
    /// name, and not hidden (the walk skips hidden files and never descends hidden folders).
    private func isListable(_ path: String) -> Bool {
        guard isTranscript(path) else { return false }
        for directory in transcriptDirectories {
            let prefix = Self.realPath(directory.path) + "/"
            guard path.hasPrefix(prefix) else { continue }
            if path.dropFirst(prefix.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                return false
            }
            let hidden = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isHiddenKey]).isHidden
            return hidden != true
        }
        return false
    }

    /// The path the kernel reports for `path`: what a directory walk and a file watcher both
    /// use (`/var/…` becomes `/private/var/…`). Falls back to `path` while it does not exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - First-read order

    /// The order to read a history in for the first time, and which transcripts are `live`:
    /// part of a session that has been written to since `liveSince`.
    ///
    /// Live sessions come first, the most recent session first, and each session's files
    /// oldest first, so the session tracker meets a session's records roughly in the order
    /// they were written. A Claude session's subagent and workflow transcripts sit beside
    /// its main one and session state is built from all of them, so an old subagent
    /// transcript is live if any of its siblings is recent.
    ///
    /// The rest follow most recently written first: they can only add to the feed, and that
    /// order shows soonest which of them are too old to.
    func backfillOrder(_ files: [TranscriptFile], liveSince: Date) -> [(file: TranscriptFile, live: Bool)] {
        var lastWritten: [String: Date] = [:]
        for file in files {
            let key = sessionKey(file.path)
            if let known = lastWritten[key], known >= file.modified { continue }
            lastWritten[key] = file.modified
        }

        var live: [(file: TranscriptFile, session: String, written: Date)] = []
        var rest: [TranscriptFile] = []
        for file in files {
            let session = sessionKey(file.path)
            let written = lastWritten[session] ?? file.modified
            if written >= liveSince {
                live.append((file, session, written))
            } else {
                rest.append(file)
            }
        }
        live.sort { a, b in
            if a.written != b.written { return a.written > b.written }
            if a.session != b.session { return a.session < b.session }
            if a.file.modified != b.file.modified { return a.file.modified < b.file.modified }
            return a.file.path < b.file.path
        }
        rest.sort { a, b in a.modified != b.modified ? a.modified > b.modified : a.path < b.path }
        return live.map { ($0.file, true) } + rest.map { ($0, false) }
    }

    /// `…/<project>/<session>` for both `<session>.jsonl` and everything under
    /// `<session>/subagents/`. A Codex session is a single file.
    private func sessionKey(_ path: String) -> String {
        guard source == .claude else { return path }
        if let subagents = path.range(of: "/subagents/") { return String(path[..<subagents.lowerBound]) }
        return path.hasSuffix(".jsonl") ? String(path.dropLast(".jsonl".count)) : path
    }

    /// Treat `file` as already read without reading it. Appends that arrive later are still
    /// picked up, exactly as if the earlier part had been read (see `resume`).
    func skip(_ file: TranscriptFile, offsets: inout [String: UInt64]) {
        offsets[file.path] = file.size
        skipped.insert(file.path)
    }

    // MARK: - Scanning

    /// Full one-shot scan of every transcript. Used by `--dump` and as the implicit
    /// first poll (when all offsets start at 0).
    public func fullScan() -> [CommandEvent] {
        reset()
        var offsets: [String: UInt64] = [:]
        return parseDelta(offsets: &offsets)
    }

    public func reset() {
        codexContexts.removeAll()
        skipped.removeAll()
    }

    /// Stream every newly-appended, complete line since the last call, invoking `onLine`
    /// with the line and its file path. Mutates `offsets` in place. Newly-discovered files
    /// are read from the beginning; truncated/rotated files reset; vanished files are pruned.
    /// `onLine` is called synchronously and must not escape.
    public func scanDelta(offsets: inout [String: UInt64], onLine: (Substring, String) -> Void) {
        let files = listFiles()
        for file in files {
            readLines(of: file, offsets: &offsets) { line, path in
                onLine(Substring(String(decoding: line, as: UTF8.self)), path)
            }
        }
        prune(offsets: &offsets, keeping: files)
    }

    /// `scanDelta` for a list the caller already has, with each line parsed once into the
    /// JSON object that both the event parsers and the session tracker read. No directory
    /// walk and no pruning: an idle watcher must not pay for either.
    func read(
        _ files: [TranscriptFile],
        offsets: inout [String: UInt64],
        onRecord: ([String: Any], String) -> Void
    ) {
        for file in files {
            readLines(of: file, offsets: &offsets) { line, path in
                if let record = Self.record(fromLine: line) { onRecord(record, path) }
            }
        }
    }

    /// `read` for transcripts that only matter to the feed: just their events, parsing only
    /// the lines that could hold one. In a Codex history most bytes are tool output and
    /// images, which this passes over without decoding.
    func readEvents(_ files: [TranscriptFile], offsets: inout [String: UInt64]) -> [CommandEvent] {
        let markers = source == .claude ? TranscriptParser.eventMarkers : CodexTranscriptParser.eventMarkers
        var events: [CommandEvent] = []
        for file in files {
            readLines(of: file, offsets: &offsets) { line, path in
                guard markers.match(line), let record = Self.record(fromLine: line) else { return }
                events.append(contentsOf: self.events(fromRecord: record, transcriptPath: path))
            }
        }
        return events
    }

    /// Reclaim offset entries for files that have been deleted or rotated away, so the
    /// map can't grow without bound over a long-running session.
    func prune(offsets: inout [String: UInt64], keeping files: [TranscriptFile]) {
        guard offsets.count > files.count else { return }
        let live = Set(files.map(\.path))
        offsets = offsets.filter { live.contains($0.key) }
        codexContexts = codexContexts.filter { live.contains($0.key) }
        skipped = skipped.filter { live.contains($0) }
    }

    /// Drop everything remembered about one vanished file.
    func forget(_ path: String, offsets: inout [String: UInt64]) {
        offsets[path] = nil
        codexContexts[path] = nil
        skipped.remove(path)
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

    func events(fromRecord record: [String: Any], transcriptPath path: String) -> [CommandEvent] {
        switch source {
        case .claude:
            return TranscriptParser.events(fromRecord: record, transcriptPath: path)
        case .codex:
            var context = codexContexts[path] ?? CodexTranscriptParser.FileContext()
            let events = CodexTranscriptParser.events(fromRecord: record, transcriptPath: path, context: &context)
            codexContexts[path] = context
            return events
        }
    }

    /// The JSON object on one line. Bytes that are not valid UTF-8 are repaired first, as
    /// they were when every line went through `String`, so the same lines keep parsing.
    static func record(fromLine line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        // The parser copies what it keeps, so it can read the scanner's buffer in place.
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        if let object = try? JSONSerialization.jsonObject(with: data) { return object as? [String: Any] }
        guard String(data: data, encoding: .utf8) == nil else { return nil }
        let repaired = Data(String(decoding: data, as: UTF8.self).utf8)
        return (try? JSONSerialization.jsonObject(with: repaired)) as? [String: Any]
    }

    // MARK: - Low level

    /// Hands `onLine` every complete line `file` has gained since `offsets`, and advances
    /// the offset past them.
    private func readLines(
        of file: TranscriptFile,
        offsets: inout [String: UInt64],
        onLine: (UnsafeRawBufferPointer, String) -> Void
    ) {
        let path = file.path
        let previous = offsets[path] ?? 0
        if file.size == previous { return }                       // unchanged
        var start: UInt64 = file.size < previous ? 0 : previous   // shrunk → re-read
        if skipped.remove(path) != nil, start > 0 {
            start = resume(path, at: start)
        }

        var first = true
        work.filesRead += 1
        let end = streamLines(path, from: start) { line in
            if first {
                first = false
                if start == 0 && source == .codex {
                    codexContexts[path] = CodexTranscriptParser.FileContext()
                }
            }
            onLine(line, path)
        }
        // With no complete line available yet, remember where we are so we don't
        // re-read the partial bytes next tick.
        offsets[path] = end ?? start
    }

    /// A skipped file grew. Returns where its next unread line starts (`offset` was the file
    /// size when it was skipped, which may fall inside a line that was still being written)
    /// and rebuilds the Codex context the skipped part would have left behind.
    private func resume(_ path: String, at offset: UInt64) -> UInt64 {
        let start = lineStart(path, atOrBefore: offset)
        if source == .codex && start > 0 {
            var context = CodexTranscriptParser.FileContext()
            let markers = CodexTranscriptParser.eventMarkers
            _ = streamLines(path, from: 0, upTo: start) { line in
                guard markers.match(line), let record = Self.record(fromLine: line) else { return }
                _ = CodexTranscriptParser.events(fromRecord: record, transcriptPath: path, context: &context)
            }
            codexContexts[path] = context
        }
        return start
    }

    /// The offset just past the last newline before `offset` (0 if there is none).
    private func lineStart(_ path: String, atOrBefore offset: UInt64) -> UInt64 {
        guard offset > 0, let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        var end = offset
        while end > 0 {
            let begin = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
            guard (try? handle.seek(toOffset: begin)) != nil,
                  let chunk = try? handle.read(upToCount: Int(end - begin)), !chunk.isEmpty
            else { return 0 }
            if let newline = chunk.lastIndex(of: 0x0A) {
                return begin + UInt64(newline - chunk.startIndex) + 1
            }
            end = begin
        }
        return 0
    }

    /// Calls `onLine` for each complete, non-empty line in `[start, limit)` (to the end of
    /// the file by default). The file is read through one buffer that only grows to the
    /// longest line, so a transcript of hundreds of megabytes never has to fit in memory.
    /// The bytes are only valid during the call.
    /// Returns the offset just past the last newline, so a half-written JSON line is never
    /// handed to the parser, or nil when no complete line was available.
    private func streamLines(
        _ path: String,
        from start: UInt64,
        upTo limit: UInt64 = .max,
        onLine: (UnsafeRawBufferPointer) -> Void
    ) -> UInt64? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let seek = off_t(exactly: start), lseek(fd, seek, SEEK_SET) >= 0 else { return nil }

        var capacity = chunkSize
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var held = 0                // bytes at the front of the buffer: a line with no newline yet
        var position = start        // file offset of the next unread byte
        var lineEnd: UInt64?        // offset just past the last newline seen
        while position < limit {
            if held == capacity {
                // A line longer than the buffer: grow until it fits.
                let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 1)
                grown.copyMemory(from: buffer, byteCount: held)
                buffer.deallocate()
                buffer = grown
                capacity *= 2
            }
            let want = Int(min(UInt64(capacity - held), limit - position))
            let count = Darwin.read(fd, buffer + held, want)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            let end = held + count
            position += UInt64(count)
            work.bytesRead += UInt64(count)

            var lineStart = 0
            var searched = held
            // Parsing leaves autoreleased objects behind; without a pool per chunk they
            // pile up until the whole scan returns.
            autoreleasepool {
                while searched < end, let hit = memchr(buffer + searched, 0x0A, end - searched) {
                    let newline = UnsafeRawPointer(buffer).distance(to: UnsafeRawPointer(hit))
                    if newline > lineStart {
                        onLine(UnsafeRawBufferPointer(start: buffer + lineStart, count: newline - lineStart))
                    }
                    lineStart = newline + 1
                    searched = lineStart
                    lineEnd = position - UInt64(end - lineStart)
                }
            }
            held = end - lineStart
            if held > 0 && lineStart > 0 { buffer.copyMemory(from: buffer + lineStart, byteCount: held) }
        }
        return lineEnd
    }
}
