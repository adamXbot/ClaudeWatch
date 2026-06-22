import XCTest
@testable import ClaudeWatchCore

final class TranscriptHTMLRendererTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeTranscript(_ lines: [[String: Any]]) throws -> String {
        let f = tmp.appendingPathComponent("session.jsonl")
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: f)
        return f.path
    }

    func testRendersHighlightAndEscapesContent() throws {
        let path = try writeTranscript([
            ["type": "user", "sessionId": "s", "cwd": "/p", "timestamp": "2026-06-22T01:14:40.425Z",
             "message": ["role": "user", "content": "delete <script>alert(1)</script> please"]],
            ["type": "assistant", "sessionId": "s", "cwd": "/p", "timestamp": "2026-06-22T01:14:41.000Z",
             "message": ["role": "assistant", "content": [
                ["type": "tool_use", "name": "Bash", "id": "toolu_target",
                 "input": ["command": "echo \"<b>hi</b>\" && rm -rf x"]],
             ]]],
        ])

        let html = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: path, highlightId: "toolu_target"))

        // Document shell + the highlighted, anchored command.
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("id=\"toolu_target\""))
        XCTAssertTrue(html.contains("class=\"tool target\""))

        // The raw markup from the transcript must be escaped, not emitted live.
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;b&gt;hi&lt;/b&gt;"))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptHTMLRenderer.render(transcriptPath: "/no/such/file.jsonl", highlightId: "x"))
    }
}
