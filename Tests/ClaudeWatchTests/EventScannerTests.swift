import XCTest
@testable import ClaudeWatchCore

final class EventScannerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func bashLine(_ command: String, id: String) -> String {
        let obj: [String: Any] = [
            "type": "assistant",
            "sessionId": "s",
            "cwd": "/p",
            "timestamp": "2026-06-22T01:14:40.425Z",
            "message": ["role": "assistant", "content": [
                ["type": "tool_use", "name": "Bash", "id": id, "input": ["command": command]],
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ text: String, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let h = try FileHandle(forWritingTo: file)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: file)
        }
    }

    func testFullScanFindsEvents() throws {
        let f = tmp.appendingPathComponent("a.jsonl")
        try append(bashLine("one", id: "t1") + "\n", to: f)
        try append(bashLine("two", id: "t2") + "\n", to: f)

        let scanner = EventScanner(root: tmp)
        let events = scanner.fullScan()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.primary)), ["one", "two"])
    }

    func testIncrementalDeltaOnlyReturnsNewLines() throws {
        let f = tmp.appendingPathComponent("a.jsonl")
        try append(bashLine("first", id: "t1") + "\n", to: f)

        let scanner = EventScanner(root: tmp)
        var offsets: [String: UInt64] = [:]

        let firstPass = scanner.parseDelta(offsets: &offsets)
        XCTAssertEqual(firstPass.map(\.primary), ["first"])

        // Nothing new yet.
        XCTAssertTrue(scanner.parseDelta(offsets: &offsets).isEmpty)

        // Append a second line; only it should come back.
        try append(bashLine("second", id: "t2") + "\n", to: f)
        let secondPass = scanner.parseDelta(offsets: &offsets)
        XCTAssertEqual(secondPass.map(\.primary), ["second"])
    }

    func testPartialLineIsNotParsedUntilNewline() throws {
        let f = tmp.appendingPathComponent("a.jsonl")
        let line = bashLine("partial", id: "t1")
        try append(line, to: f)   // no trailing newline yet

        let scanner = EventScanner(root: tmp)
        var offsets: [String: UInt64] = [:]
        XCTAssertTrue(scanner.parseDelta(offsets: &offsets).isEmpty, "incomplete line must not parse")

        try append("\n", to: f)   // line completed
        XCTAssertEqual(scanner.parseDelta(offsets: &offsets).map(\.primary), ["partial"])
    }

    func testOffsetsAreReclaimedForDeletedFiles() throws {
        let f = tmp.appendingPathComponent("a.jsonl")
        try append(bashLine("x", id: "t1") + "\n", to: f)

        let scanner = EventScanner(root: tmp)
        var offsets: [String: UInt64] = [:]
        _ = scanner.parseDelta(offsets: &offsets)
        XCTAssertEqual(offsets.count, 1)

        try FileManager.default.removeItem(at: f)
        _ = scanner.parseDelta(offsets: &offsets)
        XCTAssertEqual(offsets.count, 0, "offset entry for a deleted file should be pruned")
    }
}
