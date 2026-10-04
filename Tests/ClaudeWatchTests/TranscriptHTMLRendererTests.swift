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

    func testCodexScriptIsTheAnchorOfEveryCallInIt() throws {
        let folder = tmp.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-a.jsonl")
        let script = #"text(await tools.exec_command({cmd:"echo <one>"})); text(await tools.exec_command({cmd:"echo two"}));"#
        let text = [
            TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
            TranscriptFixtures.codexScript(script, id: "call_script"),
            TranscriptFixtures.codexScript(#"text(await tools.exec_command({cmd:"echo three"}));"#, id: "call_other"),
        ].joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: file)

        // The second call of the first script: the row's id is the record's plus "#2".
        let html = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: file.path, highlightId: "call_script#2"))
        XCTAssertTrue(html.contains("<div class=\"tool target\" id=\"call_script\">"))
        XCTAssertTrue(html.contains("<div class=\"tool\" id=\"call_other\">"))
        XCTAssertTrue(html.contains("tools.exec_command({cmd:&quot;echo &lt;one&gt;&quot;})"), "the script as written, escaped")
    }

    /// A transcript the renderer reads as Codex: its path has to contain "/.codex/".
    private func writeCodexTranscript(_ records: [String]) throws -> String {
        let folder = tmp.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-a.jsonl")
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file.path
    }

    private func codexOutput(_ type: String, id: String, output: Any) -> String {
        TranscriptFixtures.json([
            "timestamp": "2026-10-04T01:14:41.000Z", "type": "response_item",
            "payload": ["type": type, "call_id": id, "output": output],
        ])
    }

    func testCodexListShapedOutputIsShown() throws {
        let path = try writeCodexTranscript([
            TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
            TranscriptFixtures.codexScript(#"text(await tools.exec_command({cmd:"make"}));"#, id: "call_script"),
            TranscriptFixtures.codexScriptOutput("call_script", text: "Script completed\nWall time 0.2 seconds\nOutput:\n<b>built</b> & done"),
        ])

        let html = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: path, highlightId: "call_script#1"))
        XCTAssertTrue(html.contains("<summary>tool result</summary><pre>Script completed\nWall time 0.2 seconds\nOutput:\n&lt;b&gt;built&lt;/b&gt; &amp; done</pre>"))
        XCTAssertFalse(html.contains("<b>built</b>"), "the output is escaped, not emitted live")
    }

    func testCodexOutputPartsEachStartALineAndImagesAreNamedNotEmbedded() throws {
        let image: [String: Any] = ["type": "input_image", "image_url": "data:image/png;base64,QUJDREVG", "detail": "high"]
        let parts: [[String: Any]] = [
            ["type": "input_text", "text": "Script completed\nOutput:\n"],
            ["type": "input_text", "text": "first"],
            image,
            ["type": "input_text", "text": "second"],
        ]
        // Both kinds of output record are written with a list.
        for type in ["custom_tool_call_output", "function_call_output"] {
            let path = try writeCodexTranscript([
                TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
                codexOutput(type, id: "call_a", output: parts),
                codexOutput(type, id: "call_b", output: [image]),
            ])

            let html = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: path, highlightId: "x"))
            XCTAssertTrue(html.contains("<pre>Script completed\nOutput:\nfirst\n[image]\nsecond</pre>"), type)
            XCTAssertTrue(html.contains("<pre>[image]</pre>"), "\(type): an output that is only an image")
            XCTAssertFalse(html.contains("data:image"), type)
            XCTAssertFalse(html.contains("QUJDREVG"), type)
        }
    }

    func testCodexListShapedOutputIsTruncated() throws {
        let path = try writeCodexTranscript([
            TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
            codexOutput("custom_tool_call_output", id: "call_a", output: [
                ["type": "input_text", "text": String(repeating: "a", count: 3000)],
                ["type": "input_text", "text": String(repeating: "b", count: 1500)],
            ]),
        ])

        // 3,000 + a line break + 1,500 is 4,501 characters; the first 4,000 are kept.
        let html = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: path, highlightId: "x"))
        XCTAssertTrue(html.contains("a\n" + String(repeating: "b", count: 999) + "\n… (501 more characters)</pre>"))
        XCTAssertFalse(html.contains(String(repeating: "b", count: 1000)))
    }

    func testCodexStringOutputIsStillShownAndAnEmptyOneIsNot() throws {
        let path = try writeCodexTranscript([
            TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
            codexOutput("function_call_output", id: "call_a", output: "plain <ok>"),
            codexOutput("custom_tool_call_output", id: "call_b", output: "patched"),
        ])
        let html = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: path, highlightId: "x"))
        XCTAssertTrue(html.contains("<summary>tool result</summary><pre>plain &lt;ok&gt;</pre>"))
        XCTAssertTrue(html.contains("<summary>tool result</summary><pre>patched</pre>"))

        let empty = try writeCodexTranscript([
            TranscriptFixtures.codexMeta(session: "cs", cwd: "/work/app"),
            codexOutput("function_call_output", id: "call_a", output: ""),
            codexOutput("custom_tool_call_output", id: "call_b", output: [[String: Any]]()),
            codexOutput("custom_tool_call_output", id: "call_c", output: [["type": "input_text", "text": ""]]),
        ])
        let quiet = try XCTUnwrap(TranscriptHTMLRenderer.render(transcriptPath: empty, highlightId: "x"))
        XCTAssertFalse(quiet.contains("<summary>tool result</summary>"))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptHTMLRenderer.render(transcriptPath: "/no/such/file.jsonl", highlightId: "x"))
    }
}
