import Foundation

public enum CodexTranscriptParser {
    public struct FileContext {
        public var sessionId = ""
        public var cwd = ""
        public init(sessionId: String = "", cwd: String = "") {
            self.sessionId = sessionId
            self.cwd = cwd
        }
    }

    public static func events(fromLine line: Substring, transcriptPath: String, context: inout FileContext) -> [CommandEvent] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        if obj["type"] as? String == "session_meta",
           let payload = obj["payload"] as? [String: Any] {
            if let id = payload["session_id"] as? String ?? payload["id"] as? String {
                context.sessionId = id
            }
            if let cwd = payload["cwd"] as? String {
                context.cwd = cwd
            }
            return []
        }

        guard obj["type"] as? String == "response_item",
              let payload = obj["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else { return [] }

        let timestamp = parseDate(obj["timestamp"] as? String)
        let sessionId = context.sessionId.isEmpty ? sessionIdFromPath(transcriptPath) : context.sessionId
        let cwd = context.cwd
        let project = projectName(cwd: cwd, transcriptPath: transcriptPath)
        let turnId = ((payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String)
            ?? sessionId

        switch payloadType {
        case "function_call":
            guard let name = payload["name"] as? String else { return [] }
            if name == "exec_command" {
                let args = parseJSONString(payload["arguments"] as? String)
                let command = (args["cmd"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let workdir = args["workdir"] as? String
                return [CommandEvent(
                    id: payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString,
                    source: .codex,
                    kind: .shell,
                    toolName: "exec_command",
                    primary: command.isEmpty ? "(empty command)" : command,
                    secondary: workdir.map { "in \(relativePath($0, cwd: cwd))" },
                    sessionId: sessionId,
                    cwd: cwd,
                    projectName: project,
                    timestamp: timestamp,
                    isSubagent: false,
                    gitBranch: nil,
                    transcriptPath: transcriptPath
                )]
            }
            if name == "write_stdin" {
                let args = parseJSONString(payload["arguments"] as? String)
                let chars = args["chars"] as? String ?? ""
                let sid = args["session_id"].map { "\($0)" } ?? "session"
                return [CommandEvent(
                    id: payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString,
                    source: .codex,
                    kind: .shell,
                    toolName: "write_stdin",
                    primary: chars.isEmpty ? "(stdin)" : visibleStdin(chars),
                    secondary: "sent to terminal \(sid)",
                    sessionId: sessionId,
                    cwd: cwd,
                    projectName: project,
                    timestamp: timestamp,
                    isSubagent: false,
                    gitBranch: nil,
                    transcriptPath: transcriptPath
                )]
            }
            return []

        case "custom_tool_call":
            guard payload["name"] as? String == "apply_patch" else { return [] }
            let patch = payload["input"] as? String ?? ""
            let described = describePatch(patch)
            return [CommandEvent(
                id: payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString,
                source: .codex,
                kind: .fileEdit,
                toolName: "apply_patch",
                primary: described.primary,
                secondary: described.secondary,
                sessionId: turnId,
                cwd: cwd,
                projectName: project,
                timestamp: timestamp,
                isSubagent: false,
                gitBranch: nil,
                transcriptPath: transcriptPath
            )]

        default:
            return []
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

    private static func sessionIdFromPath(_ path: String) -> String {
        let base = (path as NSString).deletingPathExtension
        return (base as NSString).lastPathComponent.replacingOccurrences(of: "rollout-", with: "")
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
