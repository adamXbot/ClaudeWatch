import XCTest
@testable import ClaudeWatchCore

final class TranscriptParserTests: XCTestCase {

    /// Build one assistant transcript line containing a single tool_use block.
    private func assistantLine(
        tool: String,
        input: [String: Any],
        sessionId: String = "sess-1",
        cwd: String = "/Users/x/proj",
        toolId: String = "toolu_1",
        extraEnvelope: [String: Any] = [:]
    ) -> Substring {
        var obj: [String: Any] = [
            "type": "assistant",
            "sessionId": sessionId,
            "cwd": cwd,
            "timestamp": "2026-06-22T01:14:40.425Z",
            "gitBranch": "main",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": tool, "id": toolId, "input": input],
                ],
            ],
        ]
        obj.merge(extraEnvelope) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return Substring(String(decoding: data, as: UTF8.self))
    }

    func testBashCommandIsParsed() {
        let line = assistantLine(tool: "Bash", input: ["command": "ls -la", "description": "list files"])
        let events = TranscriptParser.events(fromLine: line, transcriptPath: "/tmp/t.jsonl")
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.kind, .shell)
        XCTAssertEqual(e.primary, "ls -la")
        XCTAssertEqual(e.secondary, "list files")
        XCTAssertEqual(e.sessionId, "sess-1")
        XCTAssertEqual(e.projectName, "proj")
        XCTAssertFalse(e.isSubagent)
        XCTAssertEqual(e.id, "toolu_1")
    }

    func testWritePathIsMadeRelativeToCwd() {
        let line = assistantLine(
            tool: "Write",
            input: ["file_path": "/Users/x/proj/src/app.swift", "content": "abc"]
        )
        let e = TranscriptParser.events(fromLine: line, transcriptPath: "/tmp/t.jsonl")[0]
        XCTAssertEqual(e.kind, .fileWrite)
        XCTAssertEqual(e.primary, "src/app.swift")          // cwd prefix stripped
        XCTAssertEqual(e.secondary, "wrote 3 B")
    }

    func testWebSearchAndFetch() {
        let search = assistantLine(tool: "WebSearch", input: ["query": "swift menubar"])
        let s = TranscriptParser.events(fromLine: search, transcriptPath: "/tmp/t.jsonl")[0]
        XCTAssertEqual(s.kind, .webSearch)
        XCTAssertEqual(s.primary, "swift menubar")

        let fetch = assistantLine(tool: "WebFetch", input: ["url": "https://example.com", "prompt": "summarize"])
        let f = TranscriptParser.events(fromLine: fetch, transcriptPath: "/tmp/t.jsonl")[0]
        XCTAssertEqual(f.kind, .webFetch)
        XCTAssertEqual(f.primary, "https://example.com")
        XCTAssertEqual(f.secondary, "summarize")
    }

    func testReadOnlyToolsAreIgnored() {
        let line = assistantLine(tool: "Read", input: ["file_path": "/Users/x/proj/a.txt"])
        XCTAssertTrue(TranscriptParser.events(fromLine: line, transcriptPath: "/tmp/t.jsonl").isEmpty)
    }

    func testSubagentDetectionViaEnvelope() {
        let line = assistantLine(
            tool: "Bash",
            input: ["command": "echo hi"],
            extraEnvelope: ["isSidechain": true, "agentId": "agent-9"]
        )
        let e = TranscriptParser.events(fromLine: line, transcriptPath: "/tmp/t.jsonl")[0]
        XCTAssertTrue(e.isSubagent)
    }

    func testSubagentDetectionViaPath() {
        let line = assistantLine(tool: "Bash", input: ["command": "echo hi"])
        let e = TranscriptParser.events(
            fromLine: line,
            transcriptPath: "/x/projects/p/subagents/workflows/w/agent.jsonl"
        )[0]
        XCTAssertTrue(e.isSubagent)
    }

    func testMalformedLineProducesNoEvents() {
        XCTAssertTrue(TranscriptParser.events(fromLine: "not json", transcriptPath: "/tmp/t.jsonl").isEmpty)
        XCTAssertTrue(TranscriptParser.events(fromLine: "{}", transcriptPath: "/tmp/t.jsonl").isEmpty)
    }
}
