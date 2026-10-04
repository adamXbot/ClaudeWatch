import XCTest
@testable import ClaudeWatchCore

final class SessionTrackerTests: XCTestCase {

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private func date(_ s: String) -> Date { iso.date(from: s)! }

    private func assistantToolUse(id: String, ts: String, session: String = "s") -> Substring {
        let obj: [String: Any] = [
            "type": "assistant", "sessionId": session, "cwd": "/proj", "timestamp": ts,
            "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "name": "Bash", "id": id, "input": ["command": "swift test"]],
            ]],
        ]
        return line(obj)
    }
    private func toolResult(id: String, ts: String, session: String = "s") -> Substring {
        let obj: [String: Any] = [
            "type": "user", "sessionId": session, "cwd": "/proj", "timestamp": ts,
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
        ]
        return line(obj)
    }
    private func assistantEndTurn(ts: String, session: String = "s") -> Substring {
        let obj: [String: Any] = [
            "type": "assistant", "sessionId": session, "cwd": "/proj", "timestamp": ts,
            "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "done"]]],
        ]
        return line(obj)
    }
    private func userPrompt(ts: String, session: String = "s") -> Substring {
        let obj: [String: Any] = [
            "type": "user", "sessionId": session, "cwd": "/proj", "timestamp": ts,
            "message": ["content": "please continue"],
        ]
        return line(obj)
    }
    private func line(_ obj: [String: Any]) -> Substring {
        Substring(String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }

    func testPendingToolMeansWorking() {
        let tracker = SessionTracker()
        tracker.ingest(line: assistantToolUse(id: "t1", ts: "2026-06-22T10:00:00.000Z"), path: "/p/s.jsonl")

        let snap = tracker.snapshot(now: date("2026-06-22T10:00:00.000Z"))
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].state, .working)
        XCTAssertTrue(snap[0].statusText.contains("swift test"))
        XCTAssertTrue(tracker.drainDone().isEmpty)
    }

    func testWorkingToWaitingEmitsDone() {
        let tracker = SessionTracker()
        tracker.ingest(line: assistantToolUse(id: "t1", ts: "2026-06-22T10:00:00.000Z"), path: "/p/s.jsonl")
        // First snapshot establishes "working".
        _ = tracker.snapshot(now: date("2026-06-22T10:00:00.000Z"))

        // Tool finishes and the turn ends.
        tracker.ingest(line: toolResult(id: "t1", ts: "2026-06-22T10:00:05.000Z"), path: "/p/s.jsonl")
        tracker.ingest(line: assistantEndTurn(ts: "2026-06-22T10:00:05.000Z"), path: "/p/s.jsonl")

        // Snapshot well past the active window → waiting + a done transition.
        let snap = tracker.snapshot(now: date("2026-06-22T10:00:20.000Z"))
        XCTAssertEqual(snap[0].state, .waiting)
        XCTAssertEqual(snap[0].statusText, "awaiting you")

        let done = tracker.drainDone()
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].projectName, "proj")
        // Drained once, not repeated.
        XCTAssertTrue(tracker.drainDone().isEmpty)
    }

    func testFirstSightingIdleDoesNotEmitDone() {
        let tracker = SessionTracker()
        tracker.ingest(line: assistantEndTurn(ts: "2026-06-22T10:00:00.000Z"), path: "/p/s.jsonl")
        // Already idle on first observation → waiting, but NOT a working→waiting transition.
        let snap = tracker.snapshot(now: date("2026-06-22T10:01:00.000Z"))
        XCTAssertEqual(snap[0].state, .waiting)
        XCTAssertTrue(tracker.drainDone().isEmpty)
    }

    func testStuckToolBecomesWaitingButEmitsNoDone() {
        let tracker = SessionTracker()
        tracker.ingest(line: assistantToolUse(id: "t1", ts: "2026-06-22T10:00:00.000Z"), path: "/p/s.jsonl")
        _ = tracker.snapshot(now: date("2026-06-22T10:00:00.000Z"))   // working

        // The tool never returns; far past the stuck threshold.
        let snap = tracker.snapshot(now: date("2026-06-22T10:10:00.000Z"))
        XCTAssertEqual(snap[0].state, .waiting)
        XCTAssertTrue(snap[0].statusText.hasPrefix("stalled"))
        XCTAssertTrue(tracker.drainDone().isEmpty, "a dead/timed-out tool must not report 'finished'")
    }

    // MARK: - Codex

    private let codexPath = "/Users/x/.codex/sessions/2026/10/02/rollout-2026-10-02T20-50-12-abc.jsonl"

    private func codexTracker() -> SessionTracker {
        let tracker = SessionTracker()
        tracker.ingest(line: Substring(TranscriptFixtures.codexMeta(session: "cs", cwd: "/Users/x/project", at: date("2026-10-02T09:50:00.000Z"))),
                       path: codexPath)
        return tracker
    }

    private func codexTaskComplete(ts: String) -> Substring {
        line(["timestamp": ts, "type": "event_msg", "payload": ["type": "task_complete"]])
    }

    func testCodexScriptIsDescribedByItsCommand() {
        let tracker = codexTracker()
        let script = #"text(await tools.exec_command({cmd:"git status --short\ngit log -1",workdir:"/Users/x/project"}));"#
        tracker.ingest(line: Substring(TranscriptFixtures.codexScript(script, id: "c1", at: date("2026-10-02T09:50:41.000Z"))), path: codexPath)

        let running = tracker.snapshot(now: date("2026-10-02T09:50:42.000Z"))
        XCTAssertEqual(running.map(\.state), [.working])
        XCTAssertEqual(running.first?.statusText, "running: git status --short")
        XCTAssertEqual(running.first?.projectName, "project")

        tracker.ingest(line: Substring(TranscriptFixtures.codexScriptOutput("c1", at: date("2026-10-02T09:50:43.000Z"))), path: codexPath)
        tracker.ingest(line: codexTaskComplete(ts: "2026-10-02T09:50:44.000Z"), path: codexPath)

        let waiting = tracker.snapshot(now: date("2026-10-02T09:51:10.000Z"))
        XCTAssertEqual(waiting.map(\.statusText), ["awaiting you"])
        XCTAssertEqual(tracker.drainDone().map(\.statusText), ["finished: git status --short"])
    }

    func testCodexScriptWithSeveralCallsNamesTheFirstAndCountsTheRest() {
        let tracker = codexTracker()
        let script = #"""
            const r = await Promise.all([tools.exec_command({cmd:"pwd && ls"}), tools.exec_command({cmd:"swift build"})]);
            text(await tools.apply_patch("*** Begin Patch\n*** Update File: src/app.swift\n*** End Patch\n"));
            """#
        tracker.ingest(line: Substring(TranscriptFixtures.codexScript(script, id: "c1", at: date("2026-10-02T09:50:41.000Z"))), path: codexPath)
        XCTAssertEqual(tracker.snapshot(now: date("2026-10-02T09:50:42.000Z")).map(\.statusText), ["running: pwd && ls (+2 more)"])
    }

    func testCodexScriptThatOnlyLooksIsNotTheLastAction() {
        let tracker = codexTracker()
        tracker.ingest(line: Substring(TranscriptFixtures.codexExec("swift test", id: "c1", at: date("2026-10-02T09:50:30.000Z"))), path: codexPath)
        XCTAssertEqual(tracker.snapshot(now: date("2026-10-02T09:50:31.000Z")).map(\.statusText), ["running: swift test"],
                       "a command recorded the old way is described as before")
        tracker.ingest(line: line([
            "timestamp": "2026-10-02T09:50:35.000Z", "type": "response_item",
            "payload": ["type": "function_call_output", "call_id": "c1", "output": "ok"],
        ]), path: codexPath)

        let look = #"text(await tools.view_image({path:"/Users/x/project/shot.png"}));"#
        tracker.ingest(line: Substring(TranscriptFixtures.codexScript(look, id: "c2", at: date("2026-10-02T09:50:41.000Z"))), path: codexPath)
        XCTAssertEqual(tracker.snapshot(now: date("2026-10-02T09:50:42.000Z")).map(\.statusText), ["running: view_image"])

        tracker.ingest(line: Substring(TranscriptFixtures.codexScriptOutput("c2", at: date("2026-10-02T09:50:43.000Z"))), path: codexPath)
        tracker.ingest(line: codexTaskComplete(ts: "2026-10-02T09:50:44.000Z"), path: codexPath)
        _ = tracker.snapshot(now: date("2026-10-02T09:51:10.000Z"))
        XCTAssertEqual(tracker.drainDone().map(\.statusText), ["finished: swift test"])
    }

    // MARK: - Codex: which session a record belongs to

    private func codexCommand(_ command: String, id: String, turn: String, ts: String) -> Substring {
        Substring(TranscriptFixtures.codexScript(#"text(await tools.exec_command({cmd:"\#(command)"}));"#, id: id, turn: turn, at: date(ts)))
    }

    func testCodexSessionIsNotNamedAfterATurnWhenItsFirstRecordWasNeverSeen() {
        // Records appended to a transcript whose start was never read here: there has been
        // no `session_meta` to say which session they belong to.
        let path = "/Users/x/.codex/sessions/2026/10/02/rollout-2026-10-02T20-50-12-0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl"
        let tracker = SessionTracker()
        tracker.ingest(line: codexCommand("git status", id: "c1", turn: "turn-1", ts: "2026-10-02T09:50:41.000Z"), path: path)
        tracker.ingest(line: Substring(TranscriptFixtures.codexScriptOutput("c1", at: date("2026-10-02T09:50:43.000Z"))), path: path)
        tracker.ingest(line: codexTaskComplete(ts: "2026-10-02T09:50:44.000Z"), path: path)
        tracker.ingest(line: codexCommand("swift build", id: "c2", turn: "turn-2", ts: "2026-10-02T09:51:00.000Z"), path: path)

        let sessions = tracker.snapshot(now: date("2026-10-02T09:51:01.000Z"))
        XCTAssertEqual(sessions.map(\.id), ["0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"],
                       "one session, under the id in the file name (what `codex resume` takes), not under a turn")
        XCTAssertEqual(sessions.first?.statusText, "running: swift build")

        // The same whichever record comes first.
        let other = SessionTracker()
        other.ingest(line: codexTaskComplete(ts: "2026-10-02T09:50:44.000Z"), path: path)
        other.ingest(line: codexCommand("swift build", id: "c2", turn: "turn-2", ts: "2026-10-02T09:51:00.000Z"), path: path)
        XCTAssertEqual(other.snapshot(now: date("2026-10-02T09:51:01.000Z")).map(\.id), ["0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"])
    }

    func testCodexSubagentTranscriptDoesNotTakeTheSessionFromItsOwnTranscript() {
        // A session that starts a review, as most do: the review writes a transcript of its
        // own, under the same session id. The session's own transcript carries on after it.
        let tracker = codexTracker()
        let review = "/Users/x/.codex/sessions/2026/10/02/rollout-2026-10-02T20-50-20-review.jsonl"
        tracker.ingest(line: Substring(TranscriptFixtures.codexMeta(session: "cs", thread: "review-thread", cwd: "/Users/x/elsewhere", at: date("2026-10-02T09:50:20.000Z"))),
                       path: review)
        tracker.ingest(line: codexCommand("cat diff.patch", id: "r1", turn: "turn-r", ts: "2026-10-02T09:50:21.000Z"), path: review)
        tracker.ingest(line: Substring(TranscriptFixtures.codexScriptOutput("r1", at: date("2026-10-02T09:50:22.000Z"))), path: review)
        tracker.ingest(line: codexCommand("git status", id: "c1", turn: "turn-2", ts: "2026-10-02T09:50:41.000Z"), path: codexPath)

        let sessions = tracker.snapshot(now: date("2026-10-02T09:50:42.000Z"))
        XCTAssertEqual(sessions.map(\.id), ["cs"], "one session, not a second one named after the turn")
        XCTAssertEqual(sessions.first?.statusText, "running: git status")
        XCTAssertEqual(sessions.first?.transcriptPath, codexPath, "the session's own transcript is the one to open")
        XCTAssertEqual(sessions.first?.cwd, "/Users/x/project")
        XCTAssertEqual(sessions.first?.projectName, "project")
    }

    func testCodexSubagentTranscriptStandsInUntilTheSessionsOwnIsSeen() {
        let tracker = SessionTracker()
        let review = "/Users/x/.codex/sessions/2026/10/02/rollout-2026-10-02T20-50-20-review.jsonl"
        tracker.ingest(line: Substring(TranscriptFixtures.codexMeta(session: "cs", thread: "review-thread", cwd: "/Users/x/elsewhere", at: date("2026-10-02T09:50:20.000Z"))),
                       path: review)
        var sessions = tracker.snapshot(now: date("2026-10-02T09:50:21.000Z"))
        XCTAssertEqual(sessions.map(\.id), ["cs"])
        XCTAssertEqual(sessions.first?.transcriptPath, review)
        XCTAssertEqual(sessions.first?.projectName, "elsewhere")

        tracker.ingest(line: Substring(TranscriptFixtures.codexMeta(session: "cs", cwd: "/Users/x/project", at: date("2026-10-02T09:50:30.000Z"))),
                       path: codexPath)
        sessions = tracker.snapshot(now: date("2026-10-02T09:50:31.000Z"))
        XCTAssertEqual(sessions.map(\.id), ["cs"])
        XCTAssertEqual(sessions.first?.transcriptPath, codexPath)
        XCTAssertEqual(sessions.first?.projectName, "project")
    }

    func testCodexSessionForgottenAndThenWrittenToAgainKeepsItsId() {
        let tracker = codexTracker()
        tracker.ingest(line: codexCommand("git status", id: "c1", turn: "turn-1", ts: "2026-10-02T09:50:41.000Z"), path: codexPath)
        tracker.ingest(line: Substring(TranscriptFixtures.codexScriptOutput("c1", at: date("2026-10-02T09:50:43.000Z"))), path: codexPath)
        XCTAssertEqual(tracker.snapshot(now: date("2026-10-02T09:51:00.000Z")).map(\.id), ["cs"])
        XCTAssertEqual(tracker.snapshot(now: date("2026-10-04T10:00:00.000Z")), [], "idle for longer than the eviction horizon")

        // Picked up again two days later: only the new records are read.
        tracker.ingest(line: codexCommand("swift test", id: "c2", turn: "turn-2", ts: "2026-10-04T10:00:01.000Z"), path: codexPath)
        let sessions = tracker.snapshot(now: date("2026-10-04T10:00:02.000Z"))
        XCTAssertEqual(sessions.map(\.id), ["cs"])
        XCTAssertEqual(sessions.first?.cwd, "/Users/x/project")
        XCTAssertEqual(sessions.first?.projectName, "project")
    }

    func testFirstLineMatchesSplittingOnNewlines() {
        for text in [
            "", "one", "one\ntwo", "one\n", "\n\nthree\nfour", "\n", "a\r\nb", "a\r\nb\nc",
            "\r\n", "\r\nx\ny", "tab\there\n\nend", "caf\u{E9}\nnext", "e\u{301}\n\u{301}x", "\n\u{301}x\ny",
        ] {
            XCTAssertEqual(SessionTracker.firstLine(of: text), text.split(separator: "\n").first.map(String.init),
                           "\(text.debugDescription)")
        }
    }

    func testUserReplyDoesNotEmitFalseDone() {
        let tracker = SessionTracker()
        tracker.ingest(line: assistantEndTurn(ts: "2026-06-22T10:00:00.000Z"), path: "/p/s.jsonl")
        _ = tracker.snapshot(now: date("2026-06-22T10:00:20.000Z"))   // waiting (awaiting you)

        // User replies; the next snapshot during the gap before Claude responds must NOT
        // flip working→waiting and fire a spurious "done".
        tracker.ingest(line: userPrompt(ts: "2026-06-22T10:00:25.000Z"), path: "/p/s.jsonl")
        let snap = tracker.snapshot(now: date("2026-06-22T10:00:40.000Z"))
        XCTAssertEqual(snap[0].state, .waiting)
        XCTAssertFalse(snap[0].statusText.contains("awaiting you"), "cleared on a new user turn")
        XCTAssertTrue(tracker.drainDone().isEmpty)
    }
}
