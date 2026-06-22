import Foundation

/// Tracks per-session working/waiting state by reading every transcript line (not just
/// the system-touching ones): it matches `tool_use` ids against later `tool_result` ids
/// to know when a tool is still running, and reads assistant `stop_reason` to know when a
/// turn has ended. Designed to be driven from a single serial queue (no internal locking).
public final class SessionTracker {

    public struct Config {
        public var activeWindow: TimeInterval = 8      // recent streaming counts as "working"
        public var stuckThreshold: TimeInterval = 300  // pending tool older than this ⇒ assume dead
        public var showWithin: TimeInterval = 15 * 60  // only surface sessions active this recently
        public var maxShown: Int = 6
        public init() {}
    }

    private let config: Config
    public init(config: Config = Config()) { self.config = config }

    private struct State {
        var projectName = "unknown"
        var cwd = ""
        var transcriptPath = ""
        var lastActivity = Date.distantPast
        var pending: [String] = []                 // ordered pending tool_use ids
        var pendingDesc: [String: String] = [:]    // id → short description
        var lastStopReason: String?
        var lastActionSummary: String?             // last system-touching action seen
        var emittedState: SessionActivityState?    // last computed state, for transition detection
    }

    private var sessions: [String: State] = [:]
    private var doneQueue: [SessionStatus] = []    // working → waiting transitions

    // MARK: - Ingest

    public func ingest(line: Substring, path: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty
        else { return }

        let type = obj["type"] as? String
        let isSub = (obj["isSidechain"] as? Bool == true)
            || (obj["agentId"] != nil)
            || path.contains("/subagents/")

        var s = sessions[sessionId] ?? State()

        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            s.cwd = cwd
            s.projectName = (cwd as NSString).lastPathComponent
        }
        // Prefer the main session file for linking; fall back to whatever we first saw.
        if !isSub { s.transcriptPath = path }
        else if s.transcriptPath.isEmpty { s.transcriptPath = path }

        if let ts = parseDate(obj["timestamp"] as? String), ts > s.lastActivity {
            s.lastActivity = ts
        }

        if let message = obj["message"] as? [String: Any] {
            if type == "assistant" {
                s.lastStopReason = message["stop_reason"] as? String
                if let content = message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "tool_use" {
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? "tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let desc = summarize(name: name, input: input)
                        if !s.pending.contains(id) { s.pending.append(id) }
                        s.pendingDesc[id] = desc
                        if isSystemTouching(name) { s.lastActionSummary = desc }
                    }
                }
            } else if type == "user" {
                if let content = message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "tool_result" {
                        if let id = block["tool_use_id"] as? String {
                            s.pending.removeAll { $0 == id }
                            s.pendingDesc[id] = nil
                        }
                    }
                }
            }
        }

        sessions[sessionId] = s
    }

    // MARK: - Snapshot + transition detection

    /// Recompute every session's state for `now`, enqueue any working→waiting transitions,
    /// and return the sessions worth displaying (recent first).
    public func snapshot(now: Date) -> [SessionStatus] {
        var shown: [SessionStatus] = []

        for (id, var s) in sessions {
            let idle = now.timeIntervalSince(s.lastActivity)
            let state: SessionActivityState
            let text: String

            if !s.pending.isEmpty && idle < config.stuckThreshold {
                state = .working
                let desc = s.pending.last.flatMap { s.pendingDesc[$0] } ?? s.lastActionSummary ?? "a tool"
                text = "running: \(desc)"
            } else if idle < config.activeWindow {
                state = .working
                text = "working\u{2026}"
            } else if s.lastStopReason == "end_turn" {
                state = .waiting
                text = "awaiting you"
            } else {
                state = .waiting
                text = "idle \(idleString(idle))"
            }

            // Detect working → waiting (a real "done" transition, not first sighting).
            if s.emittedState == .working && state == .waiting {
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

    /// Remove and return the queued "done" transitions since the last call.
    public func drainDone() -> [SessionStatus] {
        let d = doneQueue
        doneQueue.removeAll()
        return d
    }

    // MARK: - Helpers

    private func isSystemTouching(_ name: String) -> Bool {
        ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch"].contains(name)
    }

    private func summarize(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.split(separator: "\n").first.map(String.init) ?? "shell"
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

    private func idleString(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h"
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return Self.isoFractional.date(from: s) ?? Self.isoPlain.date(from: s)
    }
}
