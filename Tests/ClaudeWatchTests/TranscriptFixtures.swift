import XCTest
@testable import ClaudeWatchCore

/// Builds small transcript trees on disk for the scanner and store tests.
struct TranscriptFixtures {

    let root: URL

    init() throws {
        // The kernel's spelling of the path (/private/var/…), which is what a directory
        // walk and a file watcher both report.
        let base = EventScanner.realPath(FileManager.default.temporaryDirectory.path)
        root = URL(fileURLWithPath: base).appendingPathComponent("cw-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A Claude assistant record running `command` through Bash.
    static func bash(_ command: String, id: String, at date: Date = Date(), session: String = "s", cwd: String = "/p") -> String {
        json([
            "type": "assistant", "sessionId": session, "cwd": cwd, "timestamp": iso.string(from: date),
            "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
                ["type": "tool_use", "name": "Bash", "id": id, "input": ["command": command]],
            ]],
        ])
    }

    /// A Claude user record answering tool call `id`.
    static func toolResult(_ id: String, at date: Date = Date(), session: String = "s") -> String {
        json([
            "type": "user", "sessionId": session, "cwd": "/p", "timestamp": iso.string(from: date),
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
        ])
    }

    /// A Claude user record typed by the person.
    static func prompt(_ text: String, at date: Date = Date(), session: String = "s", cwd: String = "/p") -> String {
        json([
            "type": "user", "sessionId": session, "cwd": cwd, "timestamp": iso.string(from: date),
            "message": ["content": text],
        ])
    }

    static func codexMeta(session: String, cwd: String, at date: Date = Date()) -> String {
        json([
            "timestamp": iso.string(from: date), "type": "session_meta",
            "payload": ["session_id": session, "cwd": cwd],
        ])
    }

    static func codexExec(_ command: String, id: String, at date: Date = Date()) -> String {
        json([
            "timestamp": iso.string(from: date), "type": "response_item",
            "payload": [
                "type": "function_call", "name": "exec_command", "call_id": id,
                "arguments": json(["cmd": command]),
            ],
        ])
    }

    /// A Codex "code mode" record as versions since mid-2026 write it: the tool is `exec`
    /// and its input is a JavaScript program that makes the real calls.
    static func codexScript(_ script: String, id: String, ordinal: Int = 1, at date: Date = Date()) -> String {
        json([
            "timestamp": iso.string(from: date), "ordinal": ordinal, "type": "response_item",
            "payload": [
                "type": "custom_tool_call", "id": "ctc_\(id)", "status": "completed", "call_id": id,
                "name": "exec", "input": script,
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1", "create_time": 1_790_934_637.2],
            ],
        ])
    }

    /// The record answering script `id`.
    static func codexScriptOutput(_ id: String, text: String = "Script completed\nWall time 0.2 seconds\nOutput:\n", ordinal: Int = 2, at date: Date = Date()) -> String {
        json([
            "timestamp": iso.string(from: date), "ordinal": ordinal, "type": "response_item",
            "payload": [
                "type": "custom_tool_call_output", "id": "ctco_\(id)", "call_id": id,
                "output": [["type": "input_text", "text": text]],
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1", "create_time": 1_790_934_647.4],
            ],
            "metadata": ["client_authored": false],
        ])
    }

    /// Appends `text` exactly as given (callers add the newline, or leave it off to model a
    /// line that is still being written). `modified` backdates the file afterwards.
    @discardableResult
    func append(_ text: String, to relativePath: String, modified: Date? = nil) throws -> URL {
        let url = file(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url)
        }
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }
}

/// Settings that live in memory, so a test leaves no preferences file behind.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

/// A watcher the test fires by hand, on the store's own queue like the real one.
final class ManualWatcher: TranscriptWatching {
    private(set) var directories: [URL] = []
    private var queue: DispatchQueue?
    private var onChange: (([String]?) -> Void)?
    var isWatching: Bool { onChange != nil }

    func start(directories: [URL], queue: DispatchQueue, onChange: @escaping ([String]?) -> Void) -> Bool {
        self.directories = directories
        self.queue = queue
        self.onChange = onChange
        return true
    }

    func stop() {
        onChange = nil
    }

    /// `paths` changed; nil means the watcher lost track.
    func report(_ paths: [String]?) {
        queue?.async { self.onChange?(paths) }
    }
}

extension XCTestCase {
    /// Spins the main run loop until `condition` holds, so main-queue publishes land.
    func waitUntil(timeout: TimeInterval = 5, _ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)", file: file, line: line)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Lets the main queue run for a moment (to show that nothing further happens).
    func settle(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
