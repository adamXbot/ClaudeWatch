import XCTest
@testable import ClaudeWatchCore

final class TranscriptStoreTests: XCTestCase {

    private var fixtures: TranscriptFixtures!
    private var stores: [TranscriptStore] = []
    private let now = Date()

    /// What `onActivity` was handed (it is called on the scan queue).
    private final class Announcements {
        private let lock = NSLock()
        private var events: [CommandEvent] = []
        func add(_ new: [CommandEvent]) { lock.lock(); events += new; lock.unlock() }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return events.map(\.id) }
    }

    override func setUpWithError() throws {
        fixtures = try TranscriptFixtures()
    }

    override func tearDown() {
        for store in stores {
            store.stop()
            store.onScanQueue {}
        }
        stores.removeAll()
        fixtures.remove()
    }

    /// A store that does nothing the test did not cause: its watcher reports only what the
    /// test fires. With `watcher: nil` the store polls, and lists the directory again every
    /// few intervals, so what `scanner.work` counts then depends on how long the test took.
    private func makeStore(
        source: TranscriptSource = .claude,
        root: URL? = nil,
        maxEvents: Int = 2000,
        watcher: TranscriptWatching? = ManualWatcher()
    ) -> (store: TranscriptStore, scanner: EventScanner, announced: Announcements) {
        let scanner = EventScanner(source: source, root: root ?? fixtures.root)
        let store = TranscriptStore(scanner: scanner, interval: 0.02, maxEvents: maxEvents, watcher: watcher)
        let announced = Announcements()
        store.onActivity = { events, _ in announced.add(events) }
        stores.append(store)
        return (store, scanner, announced)
    }

    private func bash(_ command: String, id: String, at date: Date, session: String = "s") -> String {
        TranscriptFixtures.bash(command, id: id, at: date, session: session) + "\n"
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    /// Five sessions, two events each, last written 10, 8, 6, 4 and 2 days ago.
    private func writeFiveOldSessions() throws {
        for (index, days) in [10.0, 8, 6, 4, 2].enumerated() {
            let written = daysAgo(days)
            let text = bash("cmd \(index) a", id: "e\(index)a", at: written.addingTimeInterval(-7200), session: "s\(index)")
                + bash("cmd \(index) b", id: "e\(index)b", at: written.addingTimeInterval(-3600), session: "s\(index)")
            try fixtures.append(text, to: "proj/session-\(index).jsonl", modified: written)
        }
    }

    // MARK: - First read

    func testFirstReadShowsTheNewestEventsAndLeavesOlderFilesUnopened() throws {
        try writeFiveOldSessions()
        let everything = EventScanner(root: fixtures.root).fullScan().sorted { $0.timestamp > $1.timestamp }

        let (store, scanner, announced) = makeStore(maxEvents: 3)
        XCTAssertTrue(store.isLoading)
        store.start()
        waitUntil("the feed is loaded") { !store.isLoading && store.events.count == 3 }

        XCTAssertEqual(store.events.map(\.id), everything.prefix(3).map(\.id), "exactly what reading everything shows")
        XCTAssertEqual(store.events.map(\.id), ["e4b", "e4a", "e3b"])
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.listings, 1)
        XCTAssertEqual(scanner.work.filesRead, 2, "three sessions are older than anything the feed can show")
        XCTAssertEqual(announced.ids, [], "history is shown, not announced")
    }

    func testFirstReadTakesEverythingWhenTheFeedHasRoom() throws {
        try writeFiveOldSessions()
        let (store, scanner, _) = makeStore()
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 10 }
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.filesRead, 5)
    }

    func testOldTranscriptOfALiveSessionStillCountsTowardsItsState() throws {
        // Session LIVE: a tool call a subagent never finished, three days ago, and a
        // prompt ten minutes ago. Its state depends on the old transcript, however full
        // the feed is with newer events from elsewhere.
        try fixtures.append(
            TranscriptFixtures.bash("sleep 100", id: "dangling", at: daysAgo(3), session: "LIVE", cwd: "/work/worktree") + "\n",
            to: "proj/LIVE/subagents/agent-1.jsonl", modified: daysAgo(3)
        )
        try fixtures.append(
            TranscriptFixtures.prompt("carry on", at: now.addingTimeInterval(-600), session: "LIVE", cwd: "/work/app") + "\n",
            to: "proj/LIVE.jsonl"
        )
        try fixtures.append(bash("newer", id: "n1", at: now.addingTimeInterval(-3600), session: "OTHER"),
                            to: "proj/OTHER.jsonl", modified: now.addingTimeInterval(-3600))

        let (store, scanner, _) = makeStore(maxEvents: 1)
        store.start()
        waitUntil("sessions are published") { store.sessions.contains { $0.id == "LIVE" } }

        XCTAssertEqual(store.sessions.first { $0.id == "LIVE" }?.statusText, "stalled: sleep 100")
        XCTAssertEqual(store.sessions.first { $0.id == "LIVE" }?.projectName, "app",
                       "a session's files are read oldest first, so its latest record has the last word")
        XCTAssertEqual(store.events.map(\.id), ["n1"])
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.filesRead, 3)
    }

    func testSkippedFileIsFollowedOnceItGrows() throws {
        try writeFiveOldSessions()
        let watcher = ManualWatcher()
        let (store, _, announced) = makeStore(maxEvents: 3, watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 3 }

        // The oldest session, never opened, is resumed.
        let resumed = try fixtures.append(bash("back again", id: "fresh", at: Date(), session: "s0"), to: "proj/session-0.jsonl")
        watcher.report([resumed.path])
        waitUntil("the new event is shown") { store.events.first?.id == "fresh" }

        XCTAssertEqual(store.events.map(\.id), ["fresh", "e4b", "e4a"])
        store.onScanQueue {}
        XCTAssertFalse(announced.ids.contains("e0a"), "what was skipped is not replayed")
        XCTAssertTrue(announced.ids.contains("fresh"))
    }

    // MARK: - Following changes

    func testAppendNamedByTheWatcherIsReadWithoutListingAgain() throws {
        let file = try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, scanner, announced) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }
        XCTAssertEqual(watcher.directories, [fixtures.root])

        try fixtures.append(bash("two", id: "t2", at: daysAgo(1)), to: "p/a.jsonl")
        try fixtures.append("x", to: "p/notes.txt")
        watcher.report([fixtures.file("p/notes.txt").path, file.path])
        waitUntil("the append is shown") { store.events.count == 2 }

        XCTAssertEqual(store.events.map(\.id), ["t2", "t1"])
        store.onScanQueue {}
        XCTAssertEqual(announced.ids, ["t2"])
        XCTAssertEqual(scanner.work.listings, 1, "the watcher said which file; nothing was listed")
        XCTAssertEqual(scanner.work.filesRead, 2)
    }

    func testNewFileNamedByTheWatcherIsRead() throws {
        try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, scanner, _) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }

        let created = try fixtures.append(bash("two", id: "t2", at: daysAgo(1)), to: "p/b/subagents/agent-1.jsonl")
        let hidden = try fixtures.append(bash("no", id: "t3", at: daysAgo(1)), to: "p/.trash/c.jsonl")
        watcher.report([hidden.path, created.path])
        waitUntil("the new file is shown") { store.events.count == 2 }

        settle()
        XCTAssertEqual(store.events.map(\.id), ["t2", "t1"], "a hidden folder is not part of the history")
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.listings, 1)
    }

    func testIdleStoreDoesNothing() throws {
        try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, scanner, _) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }

        store.onScanQueue {}
        let before = scanner.work
        XCTAssertFalse(store.onScanQueue { store.isClockRunning }, "no session is recent enough to change with time")
        settle(0.3)                                   // fifteen of the old one-per-interval ticks
        store.onScanQueue {}
        XCTAssertEqual(scanner.work, before, "no listing, no file opened")
    }

    func testClockRunsWhileASessionIsOnShow() throws {
        try fixtures.append(bash("one", id: "t1", at: Date()), to: "p/a.jsonl")
        let (store, _, _) = makeStore(watcher: ManualWatcher())
        store.start()
        waitUntil("the session is shown") { !store.sessions.isEmpty }
        XCTAssertTrue(store.onScanQueue { store.isClockRunning })
    }

    func testWatcherLosingTrackListsAgain() throws {
        try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, scanner, _) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }

        try fixtures.append(bash("two", id: "t2", at: daysAgo(1)), to: "p/moved-in/b.jsonl")
        watcher.report(nil)
        waitUntil("the listing finds the new file") { store.events.count == 2 }
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.listings, 2)
    }

    func testWithoutAWatcherChangesAreFoundByPolling() throws {
        try fixtures.append(bash("one", id: "t1", at: daysAgo(3)), to: "p/a.jsonl")
        let (store, _, _) = makeStore(watcher: nil)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }

        try fixtures.append(bash("two", id: "t2", at: daysAgo(2)), to: "p/a.jsonl")
        waitUntil("the append is found") { store.events.count == 2 }
        try fixtures.append(bash("three", id: "t3", at: daysAgo(1)), to: "p/b.jsonl")
        waitUntil("the new file is found") { store.events.count == 3 }
        XCTAssertEqual(store.events.map(\.id), ["t3", "t2", "t1"])
    }

    // MARK: - Codex sessions

    private func codexCommand(_ command: String, id: String, turn: String, at date: Date) -> String {
        TranscriptFixtures.codexScript(#"text(await tools.exec_command({cmd:"\#(command)"}));"#, id: id, turn: turn, at: date) + "\n"
    }

    func testOldCodexSessionWrittenToAgainIsTrackedUnderItsSessionId() throws {
        // Two sessions that ended days ago. The first read takes the newer one's events
        // without tracking it, and never opens the older one: the feed is full by then.
        let recent = ".codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001.jsonl"
        let older = ".codex/sessions/2026/09/28/rollout-2026-09-28T09-00-00-0199aaaa-bbbb-7ccc-8ddd-eeeeffff0002.jsonl"
        try fixtures.append(
            TranscriptFixtures.codexMeta(session: "recent-session", cwd: "/work/app", at: daysAgo(2)) + "\n"
                + TranscriptFixtures.codexExec("make", id: "old1", at: daysAgo(2)) + "\n",
            to: recent, modified: daysAgo(2)
        )
        try fixtures.append(
            TranscriptFixtures.codexMeta(session: "older-session", cwd: "/work/site", at: daysAgo(6)) + "\n"
                + TranscriptFixtures.codexExec("ls", id: "old2", at: daysAgo(6)) + "\n",
            to: older, modified: daysAgo(6)
        )

        let watcher = ManualWatcher()
        let (store, scanner, _) = makeStore(source: .codex, root: fixtures.file(".codex"), maxEvents: 1, watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.map(\.id) == ["old1"] }
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.filesRead, 1, "the older session is not opened")
        XCTAssertEqual(store.sessions, [], "neither is recent enough to track")

        // Both are picked up again. Only the new records reach the tracker, and neither
        // file's `session_meta` is among them.
        try fixtures.append(codexCommand("swift build", id: "new1", turn: "turn-1", at: Date()), to: recent)
        try fixtures.append(codexCommand("npm test", id: "new2", turn: "turn-2", at: Date()), to: older)
        watcher.report([fixtures.file(recent).path, fixtures.file(older).path])
        waitUntil("both sessions are shown") { store.sessions.count == 2 }

        XCTAssertEqual(Set(store.sessions.map(\.id)), ["recent-session", "older-session"],
                       "the session ids `codex resume` takes, not the turns'")
        XCTAssertEqual(Set(store.sessions.map(\.projectName)), ["app", "site"])
        XCTAssertEqual(Set(store.sessions.map(\.cwd)), ["/work/app", "/work/site"])
    }

    func testCodexSessionWithAReviewTranscriptIsOneSession() throws {
        let session = "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001"
        let own = ".codex/sessions/2026/10/04/rollout-2026-10-04T09-00-00-\(session).jsonl"
        let review = ".codex/sessions/2026/10/04/rollout-2026-10-04T09-05-00-0199aaaa-bbbb-7ccc-8ddd-eeeeffff0002.jsonl"
        let started = now.addingTimeInterval(-600)
        try fixtures.append(
            TranscriptFixtures.codexMeta(session: session, cwd: "/work/app", at: started) + "\n"
                + codexCommand("git diff", id: "c1", turn: "turn-1", at: started.addingTimeInterval(10))
                + TranscriptFixtures.codexScriptOutput("c1", at: started.addingTimeInterval(11)) + "\n",
            to: own, modified: started.addingTimeInterval(11)
        )

        let watcher = ManualWatcher()
        let (store, _, _) = makeStore(source: .codex, root: fixtures.file(".codex"), watcher: watcher)
        store.start()
        waitUntil("the session is shown") { !store.sessions.isEmpty }
        XCTAssertEqual(store.sessions.map(\.id), [session])

        // The session starts a review, which writes a transcript of its own under the same
        // session id, and then carries on in its own transcript.
        try fixtures.append(
            TranscriptFixtures.codexMeta(session: session, thread: "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0002", cwd: "/work/app") + "\n"
                + codexCommand("cat diff.patch", id: "r1", turn: "turn-r", at: Date())
                + TranscriptFixtures.codexScriptOutput("r1") + "\n",
            to: review
        )
        watcher.report([fixtures.file(review).path])
        store.onScanQueue {}
        try fixtures.append(codexCommand("swift build", id: "c2", turn: "turn-2", at: Date()), to: own)
        watcher.report([fixtures.file(own).path])
        waitUntil("the new command is running") { store.sessions.contains { $0.statusText == "running: swift build" } }

        XCTAssertEqual(store.sessions.map(\.id), [session], "still one session, under its own id")
        XCTAssertEqual(store.sessions.first?.transcriptPath, fixtures.file(own).path, "and its own transcript is the one to open")
    }

    // MARK: - Starting, stopping, pausing

    func testStartDoesNotAnnounceTheBacklog() throws {
        let file = try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, _, announced) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }
        store.onScanQueue {}
        XCTAssertEqual(announced.ids, [], "history read on a start is not news")

        try fixtures.append(bash("two", id: "t2", at: daysAgo(1)), to: "p/a.jsonl")
        watcher.report([file.path])
        waitUntil("the append is shown") { store.events.count == 2 }
        store.onScanQueue {}
        XCTAssertEqual(announced.ids, ["t2"], "what happens from then on is")
    }

    func testStopKeepsTheFeedAndARestartCatchesUpQuietly() throws {
        let file = try fixtures.append(bash("one", id: "t1", at: daysAgo(3)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, _, announced) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }

        store.stop()
        store.onScanQueue {}
        XCTAssertFalse(watcher.isWatching)
        try fixtures.append(bash("two", id: "t2", at: daysAgo(2)), to: "p/a.jsonl")
        settle()
        XCTAssertEqual(store.events.map(\.id), ["t1"], "stopped: kept, not updated")

        store.start()
        waitUntil("the gap is caught up") { store.events.count == 2 }
        store.onScanQueue {}
        XCTAssertEqual(announced.ids, [], "what was missed while stopped is not announced late")

        try fixtures.append(bash("three", id: "t3", at: daysAgo(1)), to: "p/a.jsonl")
        watcher.report([file.path])
        waitUntil("the append is shown") { store.events.count == 3 }
        store.onScanQueue {}
        XCTAssertEqual(announced.ids, ["t3"])
    }

    func testLoadIfNeededReadsOnceWithoutWatching() throws {
        try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, scanner, announced) = makeStore(watcher: watcher)
        store.loadIfNeeded()
        store.loadIfNeeded()
        waitUntil("the feed is loaded") { store.events.count == 1 }
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.listings, 1)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(announced.ids, [])
    }

    func testRefreshRereadsWithoutAnnouncingAgain() throws {
        let file = try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, scanner, announced) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }
        try fixtures.append(bash("two", id: "t2", at: daysAgo(1)), to: "p/a.jsonl")
        watcher.report([file.path])
        waitUntil("the append is shown") { store.events.count == 2 }
        store.onScanQueue {}
        XCTAssertEqual(announced.ids, ["t2"])

        store.refresh()
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.listings, 2, "the refresh read everything again")
        settle()
        XCTAssertEqual(store.events.map(\.id), ["t2", "t1"])
        XCTAssertEqual(announced.ids, ["t2"], "neither the history nor what was announced once is announced again")
    }

    func testPauseHoldsReadsUntilResumed() throws {
        let file = try fixtures.append(bash("one", id: "t1", at: daysAgo(2)), to: "p/a.jsonl")
        let watcher = ManualWatcher()
        let (store, _, _) = makeStore(watcher: watcher)
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }

        store.isPaused = true
        try fixtures.append(bash("two", id: "t2", at: daysAgo(1)), to: "p/a.jsonl")
        watcher.report([file.path])
        settle()
        XCTAssertEqual(store.events.count, 1)

        store.isPaused = false
        waitUntil("the held change is read") { store.events.count == 2 }
    }

    // MARK: - The real watcher

    func testFSEventsDeliverAppendsAndNewFiles() throws {
        let file = try fixtures.append(bash("one", id: "t1", at: daysAgo(3)), to: "p/a.jsonl")
        let (store, scanner, _) = makeStore(watcher: FSEventsWatcher(latency: 0.05))
        store.start()
        waitUntil("the feed is loaded") { store.events.count == 1 }
        settle(0.3)     // let the stream settle before the writes it should report

        try fixtures.append(bash("two", id: "t2", at: daysAgo(2)), to: "p/a.jsonl")
        waitUntil(timeout: 20, "the append arrives") { store.events.count == 2 }

        try fixtures.append(bash("three", id: "t3", at: daysAgo(1)), to: "p/session/subagents/agent-1.jsonl")
        waitUntil(timeout: 20, "the new file arrives") { store.events.count == 3 }

        XCTAssertEqual(store.events.map(\.id), ["t3", "t2", "t1"])
        store.onScanQueue {}
        XCTAssertEqual(scanner.work.listings, 1, "FSEvents named the files in the form a listing uses: \(file.path)")
    }
}
