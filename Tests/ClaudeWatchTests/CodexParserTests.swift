import XCTest
@testable import ClaudeWatchCore

final class CodexParserTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> Substring {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return Substring(String(decoding: data, as: UTF8.self))
    }

    func testExecCommandUsesSessionMetaContext() {
        var context = CodexTranscriptParser.FileContext()
        let path = "/tmp/rollout-2026-07-02T11-59-07-abc.jsonl"

        _ = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-07-02T01:59:07.137Z",
            "type": "session_meta",
            "payload": [
                "session_id": "codex-session",
                "cwd": "/Users/x/project",
            ],
        ]), transcriptPath: path, context: &context)

        let events = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-07-02T02:03:46.788Z",
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": "exec_command",
                "call_id": "call_1",
                "arguments": "{\"cmd\":\"git status\",\"workdir\":\"/Users/x/project\"}",
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            ],
        ]), transcriptPath: path, context: &context)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, .codex)
        XCTAssertEqual(events[0].kind, .shell)
        XCTAssertEqual(events[0].primary, "git status")
        XCTAssertEqual(events[0].sessionId, "codex-session")
        XCTAssertEqual(events[0].projectName, "project")
    }

    func testApplyPatchIsFileEdit() {
        var context = CodexTranscriptParser.FileContext(sessionId: "s", cwd: "/repo")
        let events = CodexTranscriptParser.events(fromLine: line([
            "timestamp": "2026-07-02T02:04:45.331Z",
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "name": "apply_patch",
                "call_id": "call_patch",
                "input": "*** Begin Patch\n*** Update File: src/app.swift\n@@\n-a\n+b\n*** End Patch\n",
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            ],
        ]), transcriptPath: "/tmp/s.jsonl", context: &context)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .fileEdit)
        XCTAssertEqual(events[0].toolName, "apply_patch")
        XCTAssertEqual(events[0].primary, "src/app.swift")
        XCTAssertEqual(events[0].secondary, "1 update")
    }
}
