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
