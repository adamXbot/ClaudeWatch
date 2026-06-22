import Foundation

/// Renders a whole session transcript (.jsonl) into a readable, self-contained HTML
/// page so a command can be inspected in context in a normal browser window.
/// The `highlightId` tool_use is visually marked and scrolled into view on load.
public enum TranscriptHTMLRenderer {

    /// Render the transcript at `path`, write it to a temp file, and return the URL.
    public static func renderToTempFile(transcriptPath: String, highlightId: String) -> URL? {
        guard let html = render(transcriptPath: transcriptPath, highlightId: highlightId) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One file per highlighted command keeps repeat-opens stable and avoids clobbering.
        let safeId = highlightId.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent("thread-\(safeId).html")
        do {
            try html.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    public static func render(transcriptPath: String, highlightId: String) -> String? {
        guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return nil }

        var sessionId = ""
        var cwd = ""
        var branch: String?
        var body = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if sessionId.isEmpty { sessionId = obj["sessionId"] as? String ?? "" }
            if cwd.isEmpty { cwd = obj["cwd"] as? String ?? "" }
            if branch == nil { branch = obj["gitBranch"] as? String }

            let type = obj["type"] as? String
            guard let message = obj["message"] as? [String: Any] else { continue }
            let time = obj["timestamp"] as? String ?? ""

            if type == "user" {
                body += renderUser(message: message, time: time)
            } else if type == "assistant" {
                body += renderAssistant(message: message, time: time, highlightId: highlightId)
            }
        }

        let header = """
        <header>
          <div class="title">Claude thread</div>
          <div class="meta">
            <span><b>project</b> \(esc((cwd as NSString).lastPathComponent))</span>
            <span><b>branch</b> \(esc(branch ?? "—"))</span>
            <span><b>session</b> <code>\(esc(sessionId))</code></span>
          </div>
          <div class="path">\(esc(transcriptPath))</div>
        </header>
        """

        return page(title: "Claude thread — \((cwd as NSString).lastPathComponent)",
                    bodyHTML: header + body)
    }

    // MARK: - Turn rendering

    private static func renderUser(message: [String: Any], time: String) -> String {
        // A plain-string content is a real user prompt. Array content is tool output.
        if let str = message["content"] as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            return turn(role: "user", label: "You", time: time,
                        inner: "<div class=\"prompt\">\(esc(trimmed))</div>")
        }
        if let blocks = message["content"] as? [[String: Any]] {
            var inner = ""
            for b in blocks {
                if (b["type"] as? String) == "tool_result" {
                    let isError = (b["is_error"] as? Bool) == true
                    let content = stringify(b["content"])
                    let cls = isError ? "result error" : "result"
                    inner += "<details class=\"\(cls)\"><summary>tool result\(isError ? " · error" : "")</summary><pre>\(esc(truncate(content, 4000)))</pre></details>"
                } else if (b["type"] as? String) == "text", let t = b["text"] as? String {
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        inner += "<div class=\"prompt\">\(esc(trimmed))</div>"
                    }
                }
            }
            if inner.isEmpty { return "" }
            return turn(role: "tool", label: "Tool output", time: time, inner: inner)
        }
        return ""
    }

    private static func renderAssistant(message: [String: Any], time: String, highlightId: String) -> String {
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        var inner = ""
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { inner += "<div class=\"say\">\(esc(t))</div>" }
            case "tool_use":
                inner += renderToolUse(b, highlightId: highlightId)
            default:
                break
            }
        }
        if inner.isEmpty { return "" }
        return turn(role: "assistant", label: "Claude", time: time, inner: inner)
    }

    private static func renderToolUse(_ block: [String: Any], highlightId: String) -> String {
        let name = block["name"] as? String ?? "tool"
        let id = block["id"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        let isTarget = (id == highlightId)
        let cls = isTarget ? "tool target" : "tool"

        var detail = ""
        switch name {
        case "Bash":
            detail = "<pre>\(esc(stringValue(input["command"])))</pre>"
            if let d = input["description"] as? String, !d.isEmpty {
                detail += "<div class=\"sub\">\(esc(d))</div>"
            }
        case "Write":
            detail = "<div class=\"sub\">\(esc(stringValue(input["file_path"])))</div>"
            detail += "<pre>\(esc(truncate(stringValue(input["content"]), 3000)))</pre>"
        case "Edit":
            detail = "<div class=\"sub\">\(esc(stringValue(input["file_path"])))</div>"
            detail += "<div class=\"diff\"><pre class=\"del\">\(esc(truncate(stringValue(input["old_string"]), 2000)))</pre>"
            detail += "<pre class=\"add\">\(esc(truncate(stringValue(input["new_string"]), 2000)))</pre></div>"
        case "MultiEdit":
            if let edits = input["edits"] as? [[String: Any]] {
                detail = "<div class=\"sub\">\(esc(stringValue(input["file_path"]))) · \(edits.count) edits</div>"
                for e in edits.prefix(8) {
                    detail += "<div class=\"diff\"><pre class=\"del\">\(esc(truncate(stringValue(e["old_string"]), 1200)))</pre>"
                    detail += "<pre class=\"add\">\(esc(truncate(stringValue(e["new_string"]), 1200)))</pre></div>"
                }
            }
        case "WebFetch":
            detail = "<div class=\"sub\">\(esc(stringValue(input["url"])))</div><pre>\(esc(truncate(stringValue(input["prompt"]), 1500)))</pre>"
        case "WebSearch":
            detail = "<pre>\(esc(stringValue(input["query"])))</pre>"
        default:
            detail = "<pre>\(esc(truncate(prettyJSON(input), 2000)))</pre>"
        }

        return """
        <div class="\(cls)" id="\(esc(id))">
          <div class="toolhead"><span class="badge">\(esc(name))</span>\(isTarget ? "<span class=\"here\">this command</span>" : "")</div>
          \(detail)
        </div>
        """
    }

    // MARK: - Layout helpers

    private static func turn(role: String, label: String, time: String, inner: String) -> String {
        """
        <section class="turn \(role)">
          <div class="rolebar"><span class="role">\(esc(label))</span><span class="time">\(esc(shortTime(time)))</span></div>
          \(inner)
        </section>
        """
    }

    private static func page(title: String, bodyHTML: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>\(css)</style>
        </head><body>
        <div class="wrap">\(bodyHTML)</div>
        <script>
          const t = document.querySelector('.target');
          if (t) { t.scrollIntoView({block:'center'}); }
        </script>
        </body></html>
        """
    }

    private static let css = """
    :root{color-scheme:dark}
    *{box-sizing:border-box}
    body{margin:0;background:#0d1117;color:#c9d1d9;font:14px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
    .wrap{max-width:920px;margin:0 auto;padding:28px 20px 80px}
    header{border-bottom:1px solid #21262d;padding-bottom:16px;margin-bottom:20px}
    header .title{font-size:20px;font-weight:700;color:#f0f6fc}
    header .meta{margin-top:8px;display:flex;gap:18px;flex-wrap:wrap;color:#8b949e}
    header .meta b{color:#6e7681;font-weight:600;text-transform:uppercase;font-size:11px;letter-spacing:.04em;margin-right:4px}
    header .path{margin-top:6px;color:#6e7681;font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
    .turn{margin:18px 0;padding:14px 16px;border-radius:10px;border:1px solid #21262d}
    .turn.user{background:#161b22;border-color:#30363d}
    .turn.assistant{background:#0f1620}
    .turn.tool{background:#0d1117;opacity:.85}
    .rolebar{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
    .role{font-weight:700;color:#f0f6fc;font-size:13px}
    .time{color:#6e7681;font-size:12px}
    .prompt{white-space:pre-wrap;color:#e6edf3}
    .say{white-space:pre-wrap;color:#adbac7;margin:6px 0}
    .tool{margin:10px 0;padding:10px 12px;border-radius:8px;background:#010409;border:1px solid #21262d}
    .tool.target{border-color:#d29922;background:#1c1804;box-shadow:0 0 0 1px #d29922}
    .toolhead{display:flex;gap:10px;align-items:center;margin-bottom:6px}
    .badge{font:11px ui-monospace,Menlo,monospace;background:#1f6feb33;color:#79c0ff;padding:2px 8px;border-radius:6px;border:1px solid #1f6feb55}
    .here{font-size:11px;color:#d29922;font-weight:700;text-transform:uppercase;letter-spacing:.05em}
    pre{white-space:pre-wrap;word-break:break-word;margin:6px 0;font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#c9d1d9}
    .sub{color:#8b949e;font:12px ui-monospace,Menlo,monospace;margin-bottom:4px}
    .diff pre{padding:6px 10px;border-radius:6px;margin:3px 0}
    .diff .del{background:#3c1618;color:#ffb3b8}
    .diff .add{background:#0f2f1a;color:#a5e0b5}
    details.result{margin:8px 0;color:#8b949e}
    details.result summary{cursor:pointer;font-size:12px}
    details.result.error summary{color:#f85149}
    details.result pre{color:#8b949e;font-size:12px}
    """

    // MARK: - String utilities

    private static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func stringValue(_ any: Any?) -> String {
        (any as? String) ?? ""
    }

    /// tool_result content can be a string or an array of `{type:text,text:…}` blocks.
    private static func stringify(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let arr = any as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func prettyJSON(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "\n… (\(s.count - max) more characters)"
    }

    private static func shortTime(_ iso: String) -> String {
        // Match the event parser: fractional-seconds first, then plain ISO-8601.
        guard let date = ISO8601DateFormatter.flexible.date(from: iso)
            ?? ISO8601DateFormatter.plain.date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f.string(from: date)
    }
}

private extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
