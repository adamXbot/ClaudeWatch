import Foundation

/// Tracks per-session working/waiting state by reading every transcript line (not just the
/// system-touching ones): it matches `tool_use` ids against later `tool_result` ids to know
/// when a tool is still running, and reads the *main* thread's assistant `stop_reason` to know
/// when a turn has ended. Driven from a single serial queue (no internal locking).
///
/// "Working" is keyed off Claude's own activity — a running tool, or recent assistant output —
/// never off a user reply, so a user typing back does not produce a spurious working→waiting
/// "done" notification.
public final class SessionTracker {

    public struct Config {
        public var activeWindow: TimeInterval = 8       // recent assistant output ⇒ "working"
        public var stuckThreshold: TimeInterval = 300   // pending tool older than this ⇒ assume dead
        public var showWithin: TimeInterval = 15 * 60   // surface sessions active this recently
        public var evictionHorizon: TimeInterval = 24 * 60 * 60  // forget sessions older than this
        public var maxShown: Int = 6
        public init() {}
    }

    private let config: Config
    public init(config: Config = Config()) { self.config = config }

    /// How long after its last record a session is still tracked. A transcript nobody has
    /// written to for longer than this cannot change what `snapshot` reports.
    public var evictionHorizon: TimeInterval { config.evictionHorizon }

    private struct State {
        var projectName = "unknown"
        var cwd = ""
        var transcriptPath = ""
        var lastActivity = Date.distantPast          // any record (for idle display + eviction)
        var lastAssistantActivity = Date.distantPast // main-thread assistant output (for "working")
        var pending: [String] = []                   // pending tool_use ids (main + subagents)
        var pendingDesc: [String: String] = [:]
        var pendingTime: [String: Date] = [:]
        var lastStopReason: String?                  // main thread only
        var lastActionSummary: String?               // last system-touching action seen
        var emittedState: SessionActivityState?      // last computed state, for transition detection
    }

    private var sessions: [String: State] = [:]
    private var doneQueue: [SessionStatus] = []      // genuine working → waiting transitions

    /// What each Codex transcript's `session_meta` said, for the records that follow it.
    /// A session cannot be found by its transcript's path instead: its sub-agents and
    /// reviews write transcripts of their own under the same session id. Kept once the
    /// session is forgotten, because a file's first record is not read a second time.
    private var codexFiles: [String: CodexTranscriptParser.FileContext] = [:]

    /// What a transcript's path says about it. Asked for every record, so the answer for
    /// the file being read is kept instead of searching the path again each time.
    private var pathKind: (path: String, isCodex: Bool, isSubagent: Bool)?

    private func kind(of path: String) -> (isCodex: Bool, isSubagent: Bool) {
        if let known = pathKind, known.path == path { return (known.isCodex, known.isSubagent) }
        let kind = (isCodex: path.contains("/.codex/"), isSubagent: path.contains("/subagents/"))
        pathKind = (path, kind.isCodex, kind.isSubagent)
        return kind
    }

    // MARK: - Ingest

    public func ingest(line: Substring, path: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        ingest(record: obj, path: path)
    }

    /// The same, for a line that has already been parsed. `codexContext` is what the
    /// caller knows of a Codex transcript's `session_meta`. The scanner has it even for a
    /// file whose first record never came through here: one it read for the feed alone,
    /// or skipped, before the session was written to again.
    func ingest(record obj: [String: Any], path: String, codexContext: CodexTranscriptParser.FileContext? = nil) {
        let pathKind = kind(of: path)
        if pathKind.isCodex {
            ingestCodex(obj: obj, path: path, known: codexContext)
            return
        }

        guard
              let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty
        else { return }

        let type = obj["type"] as? String
        let isSub = (obj["isSidechain"] as? Bool == true)
            || (obj["agentId"] != nil)
            || pathKind.isSubagent
        let ts = parseDate(obj["timestamp"] as? String)

        var s = sessions[sessionId] ?? State()

        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            s.cwd = cwd
            s.projectName = (cwd as NSString).lastPathComponent
        }
        if !isSub { s.transcriptPath = path }
        else if s.transcriptPath.isEmpty { s.transcriptPath = path }
        if let ts, ts > s.lastActivity { s.lastActivity = ts }

        if let message = obj["message"] as? [String: Any] {
            if type == "assistant" {
                // stop_reason / "working" recency are driven by the MAIN thread only, so a
                // subagent's end_turn can't clobber the parent session's state.
                if !isSub {
                    s.lastStopReason = message["stop_reason"] as? String
                    if let ts, ts > s.lastAssistantActivity { s.lastAssistantActivity = ts }
                }
                if let content = message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "tool_use" {
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? "tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let desc = summarize(name: name, input: input)
                        if !s.pending.contains(id) { s.pending.append(id) }
                        s.pendingDesc[id] = desc
                        s.pendingTime[id] = ts ?? s.lastActivity
                        if isSystemTouching(name) { s.lastActionSummary = desc }
                    }
                }
            } else if type == "user" {
                if let content = message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "tool_result" {
                        if let id = block["tool_use_id"] as? String {
                            s.pending.removeAll { $0 == id }
                            s.pendingDesc[id] = nil
                            s.pendingTime[id] = nil
                        }
                    }
                } else if message["content"] is String, !isSub {
                    // A real user prompt starts a new turn — the previous end_turn no longer
                    // means "awaiting you".
                    s.lastStopReason = nil
                }
            }
        }

        sessions[sessionId] = s
    }

    private func ingestCodex(obj: [String: Any], path: String, known: CodexTranscriptParser.FileContext?) {
        let ts = parseDate(obj["timestamp"] as? String)

        var file = known ?? codexFiles[path] ?? CodexTranscriptParser.FileContext()
        if file.read(sessionMeta: obj) {
            if known == nil { codexFiles[path] = file }
            let sessionId = file.sessionId(forTranscriptAt: path)
            var s = codexState(of: sessionId, file: file, path: path)
            if let ts, ts > s.lastActivity {
                s.lastActivity = ts
                s.lastAssistantActivity = ts
            }
            sessions[sessionId] = s
            return
        }

        guard let payload = obj["payload"] as? [String: Any] else { return }

        if obj["type"] as? String == "event_msg",
           payload["type"] as? String == "task_complete" {
            let sessionId = file.sessionId(forTranscriptAt: path)
            var s = codexState(of: sessionId, file: file, path: path)
            if let ts, ts > s.lastActivity { s.lastActivity = ts }
            s.lastStopReason = "end_turn"
            sessions[sessionId] = s
            return
        }

        guard obj["type"] as? String == "response_item",
              let payloadType = payload["type"] as? String
        else { return }

        // Never the record's turn id: a session has many turns, and `codex resume` takes
        // the session.
        let sessionId = file.sessionId(forTranscriptAt: path)
        var s = codexState(of: sessionId, file: file, path: path)
        if s.projectName == "unknown" {
            s.projectName = (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "Codex"
        }
        if let ts, ts > s.lastActivity { s.lastActivity = ts }

        switch payloadType {
        case "function_call", "custom_tool_call":
            guard let id = payload["call_id"] as? String ?? payload["id"] as? String else { break }
            // The same calls the feed shows, so the two cannot disagree about what counts.
            let actions = CodexTranscriptParser.actions(in: payload)
            if !s.pending.contains(id) { s.pending.append(id) }
            s.pendingDesc[id] = summarizeCodex(payload: payload, actions: actions)
            s.pendingTime[id] = ts ?? s.lastActivity
            if let ts, ts > s.lastAssistantActivity { s.lastAssistantActivity = ts }
            if !actions.isEmpty {
                s.lastActionSummary = s.pendingDesc[id]
            }

        case "function_call_output", "custom_tool_call_output":
            if let id = payload["call_id"] as? String {
                s.pending.removeAll { $0 == id }
                s.pendingDesc[id] = nil
                s.pendingTime[id] = nil
            }
            if let ts, ts > s.lastAssistantActivity { s.lastAssistantActivity = ts }

        default:
            break
        }

        if payloadType == "message" {
            // Assistant text is live work. User messages are separate event_msg records and
            // intentionally don't make Codex appear "working".
            if let ts, ts > s.lastAssistantActivity { s.lastAssistantActivity = ts }
        }

        sessions[sessionId] = s
    }

    // MARK: - Snapshot + transition detection

    /// Recompute every session's state for `now`, enqueue genuine working→waiting transitions,
    /// evict stale sessions, and return the sessions worth displaying (recent first).
    public func snapshot(now: Date) -> [SessionStatus] {
        var shown: [SessionStatus] = []

        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            let idle = now.timeIntervalSince(s.lastActivity)

            // Forget sessions far past relevance so the map can't grow without bound.
            if idle > config.evictionHorizon {
                sessions.removeValue(forKey: id)
                continue
            }

            let assistantIdle = now.timeIntervalSince(s.lastAssistantActivity)
            let toolRunning = !s.pending.isEmpty && idle < config.stuckThreshold

            let state: SessionActivityState
            let text: String
            if toolRunning {
                state = .working
                text = "running: \(latestPendingDesc(s) ?? s.lastActionSummary ?? "a tool")"
            } else if assistantIdle < config.activeWindow {
                state = .working
                text = "working\u{2026}"
            } else if s.lastStopReason == "end_turn" {
                state = .waiting
                text = "awaiting you"
            } else if !s.pending.isEmpty {
                state = .waiting
                text = "stalled: \(latestPendingDesc(s) ?? "a tool")"
            } else {
                state = .waiting
                text = "idle \(idleString(idle))"
            }

            // A genuine "done" is working → waiting with all tools drained (not a stalled/dead
            // tool, and not a first sighting).
            if s.emittedState == .working && state == .waiting && s.pending.isEmpty {
                doneQueue.append(SessionStatus(
                    id: id, projectName: s.projectName, cwd: s.cwd,
                    transcriptPath: s.transcriptPath, state: state,
                    statusText: s.lastActionSummary.map { "finished: \($0)" } ?? "finished",
                    lastActivity: s.lastActivity
                ))
            }
            s.emittedState = state
            sessions[id] = s

            if idle < config.showWithin {
                shown.append(SessionStatus(
                    id: id, projectName: s.projectName, cwd: s.cwd,
                    transcriptPath: s.transcriptPath, state: state,
                    statusText: text, lastActivity: s.lastActivity
                ))
            }
        }

        return Array(shown.sorted { $0.lastActivity > $1.lastActivity }.prefix(config.maxShown))
    }

    public func drainDone() -> [SessionStatus] {
        let d = doneQueue
        doneQueue.removeAll()
        return d
    }

    // MARK: - Helpers

    /// Description of the most recently-started pending tool (pending order is not chronological
    /// across interleaved main + subagent files, so pick by timestamp).
    private func latestPendingDesc(_ s: State) -> String? {
        guard let id = s.pending.max(by: { (s.pendingTime[$0] ?? .distantPast) < (s.pendingTime[$1] ?? .distantPast) })
        else { return nil }
        return s.pendingDesc[id]
    }

    private func isSystemTouching(_ name: String) -> Bool {
        ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch"].contains(name)
    }

    private func summarize(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.firstLine(of: cmd) ?? "shell"
        case "Write", "Edit", "MultiEdit":
            return ((input["file_path"] as? String ?? "file") as NSString).lastPathComponent
        case "NotebookEdit":
            return ((input["notebook_path"] as? String ?? "notebook") as NSString).lastPathComponent
        case "WebFetch":
            return URL(string: input["url"] as? String ?? "")?.host ?? "web"
        case "WebSearch":
            return input["query"] as? String ?? "search"
        case "Task":
            return "subagent: \(input["subagent_type"] as? String ?? input["description"] as? String ?? "task")"
        default:
            return name
        }
    }

    /// What a Codex tool call is doing, for "running: …" and "finished: …". An `exec` script
    /// can hold several calls: the first is named and the rest are counted.
    private func summarizeCodex(payload: [String: Any], actions: [CodexTranscriptParser.Action]) -> String {
        guard let first = actions.first else {
            let name = payload["name"] as? String ?? "tool"
            // A script that only looks (an image, a web page, a terminal's output so far).
            if name == "exec", payload["type"] as? String == "custom_tool_call",
               let tool = CodexExecScript.calls(in: payload["input"] as? String ?? "").first?.tool {
                return tool
            }
            return name
        }
        let summary = summarize(first)
        return actions.count > 1 ? "\(summary) (+\(actions.count - 1) more)" : summary
    }

    private func summarize(_ action: CodexTranscriptParser.Action) -> String {
        switch action {
        case .shell(let command, _):
            let cmd = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.firstLine(of: cmd) ?? "terminal command"
        case .stdin:
            return "terminal input"
        case .patch(let patch):
            for line in (patch ?? "").split(separator: "\n") {
                if line.hasPrefix("*** Update File: ") { return String(line.dropFirst("*** Update File: ".count)) }
                if line.hasPrefix("*** Add File: ") { return String(line.dropFirst("*** Add File: ".count)) }
                if line.hasPrefix("*** Delete File: ") { return String(line.dropFirst("*** Delete File: ".count)) }
            }
            return "apply patch"
        case .script(let code, let title):
            if let title, !title.isEmpty { return title }
            return Self.firstLine(of: (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? "script"
        }
    }

    /// `text.split(separator: "\n").first`, found from the bytes instead of by walking every
    /// character of a command that may be a long script. A line feed is its own character
    /// unless a carriage return precedes it ("\r\n" is a single one, which is not "\n").
    static func firstLine(of text: String) -> String? {
        let utf8 = text.utf8
        var start = utf8.startIndex
        var previous: UInt8 = 0
        var index = start
        while index != utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A && previous != 0x0D {
                if index != start { return String(text[start..<index]) }
                start = utf8.index(after: index)        // an empty line: keep looking
            }
            previous = byte
            index = utf8.index(after: index)
        }
        return start == utf8.endIndex ? nil : String(text[start...])
    }

    /// The state so far of Codex session `id`, with what the transcript at `path` says
    /// about itself filled in. The session's own transcript is the one to open, and its
    /// folder the one to resume in; a sub-agent's stand in only until that one is seen.
    private func codexState(of id: String, file: CodexTranscriptParser.FileContext, path: String) -> State {
        var s = sessions[id] ?? State()
        if !file.isSubagent || s.transcriptPath.isEmpty { s.transcriptPath = path }
        if !file.cwd.isEmpty, file.cwd != s.cwd, !file.isSubagent || s.cwd.isEmpty {
            s.cwd = file.cwd
            s.projectName = (file.cwd as NSString).lastPathComponent
        }
        return s
    }

    private func idleString(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h"
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISOTimestamp.date(from: s)
    }
}
