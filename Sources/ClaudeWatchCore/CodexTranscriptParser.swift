import Foundation

public enum CodexTranscriptParser {
    /// What a transcript's `session_meta` says about the file. The feed and the session
    /// tracker both take a Codex file's session from here, so they cannot disagree.
    public struct FileContext {
        public var sessionId = ""
        public var cwd = ""
        /// The file was written by a sub-agent or a review that the session started. Each
        /// gets a transcript of its own, under the session's id.
        public var isSubagent = false
        public init(sessionId: String = "", cwd: String = "") {
            self.sessionId = sessionId
            self.cwd = cwd
        }

        /// Takes in a `session_meta` record. Returns false for any other record, which is
        /// left for the caller.
        mutating func read(sessionMeta record: [String: Any]) -> Bool {
            guard record["type"] as? String == "session_meta",
                  let payload = record["payload"] as? [String: Any]
            else { return false }
            // `session_id` is the session and `id` is the thread that wrote this file. They
            // are the same in the session's own transcript.
            let session = payload["session_id"] as? String
            let thread = payload["id"] as? String
            if let id = session ?? thread {
                sessionId = id
            }
            // A sub-agent's transcript goes on to repeat its parent's `session_meta`, so a
            // later record does not take this back.
            if let session, let thread, session != thread {
                isSubagent = true
            }
            if let cwd = payload["cwd"] as? String {
                self.cwd = cwd
            }
            return true
        }

        /// The session that the transcript at `path` belongs to: the one its `session_meta`
        /// named or, when that was never seen, the id in the file's name.
        func sessionId(forTranscriptAt path: String) -> String {
            sessionId.isEmpty ? CodexTranscriptParser.sessionIdFromPath(path) : sessionId
        }
    }

    /// A line that contains none of these can neither produce an event nor change the
    /// file's context, so a reader that only wants events can skip it without parsing.
    /// They are the record types `events` looks at, not the tool names, so surfacing another
    /// tool needs no change here: an `exec` script is a `custom_tool_call` like a patch.
    /// (Their `_output` counterparts, where the bulk is, differ.)
    static let eventMarkers = LineMarkers([
        #""session_meta""#, #""function_call""#, #""custom_tool_call""#,
    ])

    public static func events(fromLine line: Substring, transcriptPath: String, context: inout FileContext) -> [CommandEvent] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        return events(fromRecord: obj, transcriptPath: transcriptPath, context: &context)
    }

    /// The same, for a line that has already been parsed.
    static func events(fromRecord obj: [String: Any], transcriptPath: String, context: inout FileContext) -> [CommandEvent] {
        if context.read(sessionMeta: obj) { return [] }

        guard obj["type"] as? String == "response_item",
              let payload = obj["payload"] as? [String: Any]
        else { return [] }
        let actions = Self.actions(in: payload)
        guard !actions.isEmpty else { return [] }

        let timestamp = parseDate(obj["timestamp"] as? String)
        let sessionId = context.sessionId(forTranscriptAt: transcriptPath)
        let cwd = context.cwd
        let project = projectName(cwd: cwd, transcriptPath: transcriptPath)
        let callId = payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString

        return actions.enumerated().map { index, action in
            let described = describe(action, cwd: cwd)
            return CommandEvent(
                id: eventId(callId: callId, index: index),
                source: .codex,
                kind: described.kind,
                toolName: described.toolName,
                primary: described.primary,
                secondary: described.secondary,
                sessionId: sessionId,
                cwd: cwd,
                projectName: project,
                timestamp: timestamp,
                isSubagent: false,
                gitBranch: nil,
                transcriptPath: transcriptPath
            )
        }
    }

    // MARK: - Actions

    /// A system-touching call, however the transcript recorded it.
    enum Action: Equatable {
        /// `exec_command`. A nil command is one a script works out as it runs.
        case shell(command: String?, workdir: String?)
        /// `write_stdin`: text typed into a terminal that a command left open.
        case stdin(chars: String?, terminal: String?)
        /// `apply_patch`.
        case patch(String?)
        /// `js`: JavaScript run in Codex's Node REPL, which is also how it drives apps and
        /// the browser.
        case script(code: String?, title: String?)
    }

    /// The system-touching calls of a `response_item` payload: the one the record is (older
    /// transcripts), or the ones written in its script (an `exec` record, see `CodexExecScript`).
    static func actions(in payload: [String: Any]) -> [Action] {
        guard let name = payload["name"] as? String else { return [] }
        switch payload["type"] as? String {
        case "function_call":
            switch name {
            case "exec_command":
                let args = parseJSONString(payload["arguments"] as? String)
                return [.shell(command: args["cmd"] as? String ?? "", workdir: args["workdir"] as? String)]
            case "write_stdin":
                let args = parseJSONString(payload["arguments"] as? String)
                return [.stdin(chars: args["chars"] as? String ?? "", terminal: args["session_id"].map { "\($0)" })]
            case "js":
                let args = parseJSONString(payload["arguments"] as? String)
                return [.script(code: args["code"] as? String ?? "", title: args["title"] as? String)]
            default:
                return []
            }
        case "custom_tool_call":
            switch name {
            case "apply_patch":
                return [.patch(payload["input"] as? String ?? "")]
            case "exec":
                return CodexExecScript.calls(in: payload["input"] as? String ?? "").compactMap(action(for:))
            default:
                return []
            }
        default:
            return []
        }
    }

    private static func action(for call: CodexExecScript.Call) -> Action? {
        switch call.tool {
        case "exec_command":
            return .shell(command: call.properties["cmd"]?.text, workdir: call.properties["workdir"]?.text)
        case "write_stdin":
            // In a script nearly every write_stdin sends nothing: it is how Codex waits for
            // more output from a command that is still running. Only typed text is an action.
            switch call.properties["chars"] {
            case nil, .known("")?:
                return nil
            case let chars?:
                return .stdin(chars: chars.text, terminal: call.properties["session_id"]?.text)
            }
        case "apply_patch":
            return .patch(call.argument?.text)
        case let tool where tool == "js" || tool.hasSuffix("__js"):
            return .script(code: call.properties["code"]?.text, title: call.properties["title"]?.text)
        default:
            return nil
        }
    }

    /// The id of a record's `index`th event. A script can hold several calls and each row of
    /// the feed needs an id of its own; the first keeps the record's call id.
    static func eventId(callId: String, index: Int) -> String {
        index == 0 ? callId : "\(callId)#\(index + 1)"
    }

    /// The call id of the record that event `id` came from, where the thread view anchors.
    static func callId(ofEvent id: String) -> String {
        guard let hash = id.lastIndex(of: "#") else { return id }
        let number = id[id.index(after: hash)...]
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return id }
        return String(id[..<hash])
    }

    private static func describe(_ action: Action, cwd: String) -> (kind: EventKind, toolName: String, primary: String, secondary: String?) {
        switch action {
        case .shell(let command, let workdir):
            let primary = command.map { command in
                let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
                return command.isEmpty ? "(empty command)" : command
            }
            return (.shell, "exec_command", primary ?? "(computed command)", workdir.map { "in \(relativePath($0, cwd: cwd))" })

        case .stdin(let chars, let terminal):
            let primary = chars.map { $0.isEmpty ? "(stdin)" : visibleStdin($0) }
            return (.shell, "write_stdin", primary ?? "(computed input)", "sent to terminal \(terminal ?? "session")")

        case .patch(let patch):
            guard let patch else { return (.fileEdit, "apply_patch", "(computed patch)", "patch") }
            let described = describePatch(patch)
            return (.fileEdit, "apply_patch", described.primary, described.secondary)

        case .script(let code, let title):
            let primary = code.map { code in
                let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
                return code.isEmpty ? "(empty script)" : code
            }
            return (.shell, "js", primary ?? "(computed script)", title.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private static func parseJSONString(_ s: String?) -> [String: Any] {
        guard let s, let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func describePatch(_ patch: String) -> (primary: String, secondary: String?) {
        var files: [String] = []
        var adds = 0
        var updates = 0
        var deletes = 0
        for line in patch.split(separator: "\n") {
            if line.hasPrefix("*** Add File: ") {
                adds += 1; files.append(String(line.dropFirst("*** Add File: ".count)))
            } else if line.hasPrefix("*** Update File: ") {
                updates += 1; files.append(String(line.dropFirst("*** Update File: ".count)))
            } else if line.hasPrefix("*** Delete File: ") {
                deletes += 1; files.append(String(line.dropFirst("*** Delete File: ".count)))
            }
        }
        let primary = files.first ?? "apply_patch"
        let pieces = [
            adds > 0 ? "\(adds) add\(adds == 1 ? "" : "s")" : nil,
            updates > 0 ? "\(updates) update\(updates == 1 ? "" : "s")" : nil,
            deletes > 0 ? "\(deletes) delete\(deletes == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        return (primary, pieces.isEmpty ? "patch" : pieces.joined(separator: ", "))
    }

    private static func relativePath(_ path: String, cwd: String) -> String {
        guard !cwd.isEmpty else { return path }
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }

    private static func projectName(cwd: String, transcriptPath: String) -> String {
        if !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return (transcriptPath as NSString).deletingPathExtension
            .components(separatedBy: "/").last?
            .replacingOccurrences(of: "rollout-", with: "") ?? "Codex"
    }

    /// The id in a transcript's file name, `rollout-<started>-<id>.jsonl`. `codex resume`
    /// takes the id alone, so the time in front of it is left out. A name that is laid out
    /// differently is used whole.
    static func sessionIdFromPath(_ path: String) -> String {
        let base = (path as NSString).deletingPathExtension
        let name = (base as NSString).lastPathComponent.replacingOccurrences(of: "rollout-", with: "")
        // "2026-10-02T20-50-12-", then the id.
        let id = String(name.dropFirst(20).prefix(36))
        guard name.prefix(20).last == "-", UUID(uuidString: id) != nil else { return name }
        return id
    }

    private static func visibleStdin(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 3: out += "^C"
            case 4: out += "^D"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 13: out += "\\r"
            case 0..<32: out += String(format: "^%c", scalar.value + 64)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func parseDate(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        return ISOTimestamp.date(from: s) ?? .distantPast
    }
}
