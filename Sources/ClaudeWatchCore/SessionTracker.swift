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
