import XCTest
@testable import ClaudeWatchCore

/// What keeps a scan cheap on a large history: a narrow directory walk, an early-exit
/// existence check, bounded reads, and skipping files without losing track of them.
final class EventScannerLargeHistoryTests: XCTestCase {

    private var fixtures: TranscriptFixtures!

    override func setUpWithError() throws {
        fixtures = try TranscriptFixtures()
    }

    override func tearDown() {
        fixtures.remove()
    }

    private func line(_ command: String, id: String, at date: Date = Date()) -> String {
        TranscriptFixtures.bash(command, id: id, at: date) + "\n"
    }

    // MARK: - Discovery

    func testCodexHomeOnlyWalksItsSessionFolders() throws {
        let exec = TranscriptFixtures.codexExec("ls", id: "c1") + "\n"
        try fixtures.append(exec, to: ".codex/sessions/2026/10/04/rollout-a.jsonl")
        try fixtures.append(exec, to: ".codex/archived_sessions/rollout-b.jsonl")
        try fixtures.append(exec, to: ".codex/worktrees/repo/logs/c.jsonl")
        try fixtures.append(exec, to: ".codex/history.jsonl")

        let home = fixtures.file(".codex")
        let scanner = EventScanner(source: .codex, root: home)

        XCTAssertEqual(scanner.transcriptDirectories.map(\.lastPathComponent), ["sessions", "archived_sessions"])
        XCTAssertEqual(
            Set(scanner.discoverFiles().map(\.lastPathComponent)),
            ["rollout-a.jsonl", "rollout-b.jsonl"]
        )
        XCTAssertEqual(Set(scanner.listFiles().map { ($0.path as NSString).lastPathComponent }),
                       ["rollout-a.jsonl", "rollout-b.jsonl"])
    }

    func testCodexRootThatIsNotAHomeIsWalkedWhole() throws {
        try fixtures.append(TranscriptFixtures.codexExec("ls", id: "c1") + "\n", to: "anywhere/x.jsonl")
        let scanner = EventScanner(source: .codex, root: fixtures.root)
        XCTAssertEqual(scanner.transcriptDirectories, [fixtures.root])
        XCTAssertEqual(scanner.discoverFiles().count, 1)
    }

    func testHasFilesFindsOneTranscript() throws {
        let scanner = EventScanner(root: fixtures.root)
        XCTAssertFalse(scanner.hasFiles())

        try fixtures.append("not a transcript", to: "project/notes.txt")
        XCTAssertFalse(scanner.hasFiles())

        try fixtures.append(line("one", id: "t1"), to: "project/session.jsonl")
        XCTAssertTrue(scanner.hasFiles())
        XCTAssertEqual(scanner.work.listings, 0, "an existence check is not a full listing")
    }

    func testHasFilesIgnoresACodexHomeWithoutSessions() throws {
        try fixtures.append("{}\n", to: ".codex/history.jsonl")
        try fixtures.append("{}\n", to: ".codex/worktrees/repo/x.jsonl")
        let scanner = EventScanner(source: .codex, root: fixtures.file(".codex"))
        XCTAssertFalse(scanner.hasFiles())

        try fixtures.append("{}\n", to: ".codex/sessions/2026/10/04/rollout-a.jsonl")
        XCTAssertTrue(scanner.hasFiles())
    }

    func testListingCarriesSizeAndModificationDate() throws {
        let text = line("one", id: "t1")
        let modified = Date(timeIntervalSince1970: 1_780_000_000)
        let url = try fixtures.append(text, to: "p/a.jsonl", modified: modified)

        let files = EventScanner(root: fixtures.root).listFiles()
        XCTAssertEqual(files, [TranscriptFile(path: url.path, size: UInt64(text.utf8.count), modified: modified)])
    }

    func testWatchedPathIsCheckedLikeAListing() throws {
        let scanner = EventScanner(root: fixtures.root)
        let transcript = try fixtures.append(line("one", id: "t1"), to: "p/a.jsonl")
        let hidden = try fixtures.append(line("two", id: "t2"), to: "p/.cache/b.jsonl")
        let other = try fixtures.append("x", to: "p/notes.txt")

        XCTAssertEqual(scanner.file(atPath: transcript.path, known: false)?.size, UInt64(line("one", id: "t1").utf8.count))
        XCTAssertNil(scanner.file(atPath: hidden.path, known: false), "the walk never enters hidden folders")
        XCTAssertNil(scanner.file(atPath: other.path, known: false))
        XCTAssertNil(scanner.file(atPath: fixtures.file("p/gone.jsonl").path, known: true))
    }

    // MARK: - Reading

    func testLinesLongerThanTheBufferAreReassembled() throws {
        let long = String(repeating: "x", count: 500)
        try fixtures.append(line("short", id: "t1") + line(long, id: "t2") + line("last", id: "t3"), to: "a.jsonl")

        // An 8-byte buffer: every line spans many reads and the buffer has to grow.
        let scanner = EventScanner(source: .claude, root: fixtures.root, chunkSize: 8)
        var offsets: [String: UInt64] = [:]
        XCTAssertEqual(scanner.parseDelta(offsets: &offsets).map(\.primary), ["short", long, "last"])
        XCTAssertTrue(scanner.parseDelta(offsets: &offsets).isEmpty)
    }

    func testPartialLineAcrossBufferBoundaryWaitsForItsNewline() throws {
        let whole = line("first", id: "t1")
        let partial = TranscriptFixtures.bash("second", id: "t2")
        let url = try fixtures.append(whole + partial, to: "a.jsonl")

        let scanner = EventScanner(source: .claude, root: fixtures.root, chunkSize: 16)
        var offsets: [String: UInt64] = [:]
        XCTAssertEqual(scanner.parseDelta(offsets: &offsets).map(\.primary), ["first"])
        XCTAssertEqual(offsets[url.path], UInt64(whole.utf8.count), "the offset stops at the last newline")

        try fixtures.append("\n\n", to: "a.jsonl")      // completes the line; the blank one is ignored
        XCTAssertEqual(scanner.parseDelta(offsets: &offsets).map(\.primary), ["second"])
    }

    func testLineWithInvalidUTF8IsRepairedNotDropped() throws {
        // A stray 0xFF inside the command: not valid UTF-8, so the JSON parser rejects the
        // raw bytes. Decoding it leniently first is what keeps the event.
        var bytes = Array(TranscriptFixtures.bash("echo MARK", id: "t1").utf8)
        let mark = bytes.firstIndex(of: UInt8(ascii: "M"))!
        bytes[mark] = 0xFF
        bytes.append(0x0A)
        try Data(bytes).write(to: fixtures.file("a.jsonl"))

        let scanner = EventScanner(root: fixtures.root)
        var offsets: [String: UInt64] = [:]
        var viaRecords: [CommandEvent] = []
        scanner.read(scanner.listFiles(), offsets: &offsets) { record, path in
            viaRecords.append(contentsOf: scanner.events(fromRecord: record, transcriptPath: path))
        }
        XCTAssertEqual(viaRecords.map(\.primary), ["echo \u{FFFD}ARK"])
        XCTAssertEqual(scanner.fullScan().map(\.primary), ["echo \u{FFFD}ARK"], "same through the line-based API")
    }

    func testEventsOnlyReadFindsWhatAFullParseFinds() throws {
        let claude = [
            TranscriptFixtures.prompt("please"),
            TranscriptFixtures.bash("make", id: "t1"),
            TranscriptFixtures.toolResult("t1"),
            TranscriptFixtures.json(["type": "assistant", "sessionId": "s", "message": ["content": [["type": "text", "text": "a tool_use in prose"]]]]),
            TranscriptFixtures.bash("make test", id: "t2"),
        ].joined(separator: "\n") + "\n"
        try fixtures.append(claude, to: "claude/a.jsonl")
        let codex = [
            TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
            TranscriptFixtures.json(["timestamp": "2026-07-02T01:59:07.137Z", "type": "response_item", "payload": ["type": "message", "role": "user"]]),
            TranscriptFixtures.codexExec("git status", id: "c1"),
            // What Codex writes now: the commands are calls inside an `exec` script.
            TranscriptFixtures.codexScript(#"text(await tools.exec_command({cmd:"swift build",workdir:"/work/app"}));"#, id: "c2", ordinal: 3),
            TranscriptFixtures.codexScriptOutput("c2", ordinal: 4),
            TranscriptFixtures.codexScript("""
                const results = await Promise.allSettled([
                  tools.exec_command({cmd:"git diff --stat","max_output_tokens":2000}),
                  tools.view_image({path:"/work/app/shot.png"}),
                ]);
                text(await tools.apply_patch("*** Begin Patch\\n*** Update File: Sources/App.swift\\n@@\\n-a\\n+b\\n*** End Patch\\n"));
                """, id: "c3", ordinal: 5),
            TranscriptFixtures.codexScriptOutput("c3", ordinal: 6),
        ].joined(separator: "\n") + "\n"
        try fixtures.append(codex, to: "codex/b.jsonl")

        for (source, folder) in [(TranscriptSource.claude, "claude"), (.codex, "codex")] {
            let root = fixtures.file(folder)
            let full = EventScanner(source: source, root: root).fullScan()
            let scanner = EventScanner(source: source, root: root)
            var offsets: [String: UInt64] = [:]
            let eventsOnly = scanner.readEvents(scanner.listFiles(), offsets: &offsets)
            XCTAssertEqual(eventsOnly, full, "\(source)")
            XCTAssertFalse(full.isEmpty)
            if source == .codex {
                XCTAssertEqual(full.map(\.primary), ["git status", "swift build", "git diff --stat", "Sources/App.swift"])
                XCTAssertEqual(full.map(\.id), ["c1", "c2", "c3", "c3#2"])
            }
        }
    }

    func testEventMarkersCoverEveryRecordThatYieldsACodexEvent() {
        func matches(_ line: String) -> Bool {
            Array(line.utf8).withUnsafeBytes { CodexTranscriptParser.eventMarkers.match($0) }
        }
        XCTAssertTrue(matches(TranscriptFixtures.codexScript(#"text(await tools.exec_command({cmd:"ls"}));"#, id: "c1")))
        XCTAssertTrue(matches(TranscriptFixtures.codexExec("ls", id: "c2")))
        XCTAssertTrue(matches(TranscriptFixtures.codexMeta(session: "s", cwd: "/w")))
        XCTAssertFalse(matches(TranscriptFixtures.codexScriptOutput("c1")), "outputs are the bulk of a transcript and hold no event")
    }

    // MARK: - Skipping

    func testBackfillOrderPutsLiveSessionsFirstInWritingOrder() throws {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let old = now.addingTimeInterval(-5 * 86_400)
        // Session AAA is live: its main transcript was just written, its subagents long ago.
        try fixtures.append(line("a", id: "t1"), to: "proj/AAA.jsonl", modified: now)
        try fixtures.append(line("b", id: "t2"), to: "proj/AAA/subagents/agent-1.jsonl", modified: old)
        try fixtures.append(line("c", id: "t3"), to: "proj/AAA/subagents/workflows/wf_1/agent-2.jsonl", modified: old.addingTimeInterval(-60))
        // A live session written a little earlier, and two that ended days ago.
        try fixtures.append(line("d", id: "t4"), to: "proj/BBB.jsonl", modified: now.addingTimeInterval(-600))
        try fixtures.append(line("e", id: "t5"), to: "proj/CCC.jsonl", modified: old.addingTimeInterval(60))
        try fixtures.append(line("f", id: "t6"), to: "proj/DDD.jsonl", modified: old.addingTimeInterval(120))

        let scanner = EventScanner(root: fixtures.root)
        let order = scanner.backfillOrder(scanner.listFiles(), liveSince: now.addingTimeInterval(-86_400))
        XCTAssertEqual(order.map { ($0.file.path as NSString).lastPathComponent },
                       ["agent-2.jsonl", "agent-1.jsonl", "AAA.jsonl", "BBB.jsonl", "DDD.jsonl", "CCC.jsonl"])
        XCTAssertEqual(order.map(\.live), [true, true, true, true, false, false])
    }

    func testSkippedFileIsPickedUpFromALineBoundaryWhenItGrows() throws {
        // Skipped while its last line was still being written.
        let partial = TranscriptFixtures.bash("half written", id: "t2")
        try fixtures.append(line("old", id: "t1") + String(partial.prefix(40)), to: "a.jsonl")

        let scanner = EventScanner(root: fixtures.root)
        var offsets: [String: UInt64] = [:]
        scanner.skip(scanner.listFiles()[0], offsets: &offsets)
        XCTAssertEqual(scanner.readEvents(scanner.listFiles(), offsets: &offsets), [], "nothing new yet")
        XCTAssertEqual(scanner.work.filesRead, 0)

        try fixtures.append(String(partial.dropFirst(40)) + "\n" + line("new", id: "t3"), to: "a.jsonl")
        let events = scanner.readEvents(scanner.listFiles(), offsets: &offsets)
        XCTAssertEqual(events.map(\.primary), ["half written", "new"], "the old line is not replayed, the split one is whole")
    }

    func testSkippedCodexFileKeepsItsSessionContextWhenItGrows() throws {
        let head = TranscriptFixtures.codexMeta(session: "codex-session", cwd: "/Users/x/project") + "\n"
            + TranscriptFixtures.codexExec("old command", id: "c1") + "\n"
        try fixtures.append(head, to: "rollout-2026-07-02T11-59-07-abc.jsonl")

        let scanner = EventScanner(source: .codex, root: fixtures.root)
        var offsets: [String: UInt64] = [:]
        scanner.skip(scanner.listFiles()[0], offsets: &offsets)

        try fixtures.append(TranscriptFixtures.codexExec("new command", id: "c2") + "\n", to: "rollout-2026-07-02T11-59-07-abc.jsonl")
        var events: [CommandEvent] = []
        scanner.read(scanner.listFiles(), offsets: &offsets) { record, path in
            events.append(contentsOf: scanner.events(fromRecord: record, transcriptPath: path))
        }
        XCTAssertEqual(events.map(\.primary), ["new command"])
        XCTAssertEqual(events.first?.sessionId, "codex-session", "context from the part that was never read")
        XCTAssertEqual(events.first?.projectName, "project")
    }
}
