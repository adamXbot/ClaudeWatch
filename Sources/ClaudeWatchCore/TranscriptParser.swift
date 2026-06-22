import Foundation

/// Stateless conversion of a single transcript line into zero or more `CommandEvent`s.
public enum TranscriptParser {

    /// Tool names we surface, mapped to their kind. Anything not in here is ignored.
    private static let trackedTools: [String: EventKind] = [
        "Bash": .shell,
        "Write": .fileWrite,
        "Edit": .fileEdit,
        "MultiEdit": .fileEdit,
        "NotebookEdit": .notebookEdit,
        "WebFetch": .webFetch,
        "WebSearch": .webSearch,
    ]

    /// Parse one JSONL line. Returns `[]` for any line that isn't an assistant
    /// turn containing a tracked tool_use.
    public static func events(fromLine line: Substring, transcriptPath: String) -> [CommandEvent] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        let sessionId = obj["sessionId"] as? String ?? ""
        let cwd = obj["cwd"] as? String ?? ""
        let timestamp = parseDate(obj["timestamp"] as? String)
        let branch = obj["gitBranch"] as? String
        // The tool_use `caller` field stays "direct" even inside subagents, so we
        // key subagent detection off the envelope instead.
        let isSubagent = (obj["isSidechain"] as? Bool == true)
            || (obj["agentId"] != nil)
            || transcriptPath.contains("/subagents/")
        let project = projectName(cwd: cwd, transcriptPath: transcriptPath)

        var events: [CommandEvent] = []
        for block in content {
            guard (block["type"] as? String) == "tool_use",
                  let name = block["name"] as? String,
                  let kind = trackedTools[name],
                  let id = block["id"] as? String,
                  let input = block["input"] as? [String: Any]
            else { continue }

            let described = describe(kind: kind, name: name, input: input, cwd: cwd)
            events.append(CommandEvent(
                id: id,
                kind: kind,
                toolName: name,
                primary: described.primary,
                secondary: described.secondary,
                sessionId: sessionId,
                cwd: cwd,
                projectName: project,
                timestamp: timestamp,
                isSubagent: isSubagent,
                gitBranch: branch,
                transcriptPath: transcriptPath
            ))
        }
        return events
    }

    // MARK: - Per-tool field extraction

    private static func describe(kind: EventKind, name: String, input: [String: Any], cwd: String)
        -> (primary: String, secondary: String?) {
        switch name {
        case "Bash":
            let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = input["description"] as? String
            return (cmd.isEmpty ? "(empty command)" : cmd, desc)

        case "Write":
            let path = relativePath(input["file_path"] as? String, cwd: cwd)
            let bytes = (input["content"] as? String)?.utf8.count ?? 0
            return (path, "wrote \(byteSize(bytes))")

        case "Edit":
            let path = relativePath(input["file_path"] as? String, cwd: cwd)
            let all = (input["replace_all"] as? Bool) == true
            return (path, all ? "replace all" : "edit")

        case "MultiEdit":
            let path = relativePath(input["file_path"] as? String, cwd: cwd)
            let count = (input["edits"] as? [[String: Any]])?.count ?? 0
            return (path, "\(count) edit\(count == 1 ? "" : "s")")

        case "NotebookEdit":
            let path = relativePath(input["notebook_path"] as? String, cwd: cwd)
            let mode = input["edit_mode"] as? String ?? "edit"
            return (path, "notebook \(mode)")

        case "WebFetch":
            let url = input["url"] as? String ?? "(no url)"
            let prompt = input["prompt"] as? String
            return (url, prompt)

        case "WebSearch":
            return (input["query"] as? String ?? "(no query)", nil)

        default:
            return ("\(name)", nil)
        }
    }

    // MARK: - Helpers

    /// Strip the project cwd prefix so file paths read as project-relative.
    private static func relativePath(_ path: String?, cwd: String) -> String {
        guard let path else { return "(no path)" }
        if !cwd.isEmpty {
            let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return path
    }

    private static func projectName(cwd: String, transcriptPath: String) -> String {
        if !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        // Fall back to the encoded project directory name under ~/.claude/projects.
        let comps = transcriptPath.components(separatedBy: "/projects/")
        if comps.count > 1 {
            let enc = comps[1].components(separatedBy: "/").first ?? ""
            return (enc as NSString).lastPathComponent
        }
        return "unknown"
    }

    private static func byteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // ISO-8601 with fractional seconds (e.g. "2026-06-22T01:14:40.425Z").
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s) ?? .distantPast
    }
}
