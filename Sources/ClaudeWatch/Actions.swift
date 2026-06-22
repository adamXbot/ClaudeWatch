import AppKit
import ClaudeWatchCore

/// User actions invoked from a command row.
enum Actions {

    /// Render the full thread to HTML and open it in the default browser, scrolled to
    /// the command. For subagent events this shows the subagent's own transcript —
    /// i.e. exactly the thread that issued the command.
    static func openInBrowser(_ event: CommandEvent) {
        guard let url = TranscriptHTMLRenderer.renderToTempFile(
            transcriptPath: event.transcriptPath,
            highlightId: event.id
        ) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Resume the originating session in Claude Code by opening Terminal in the project
    /// directory and running `claude --resume <sessionId>`. Subagents can't be resumed
    /// directly, so we resume their parent session (the envelope's sessionId).
    static func resumeInClaudeCode(_ event: CommandEvent) {
        let cwd = event.cwd
        let session = event.sessionId
        guard !session.isEmpty else { NSSound.beep(); return }

        let cdPart = cwd.isEmpty ? "" : "cd \(shQuote(cwd)) && "
        let shellCommand = "\(cdPart)claude --resume \(shQuote(session))"
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscape(shellCommand))"
        end tell
        """
        runOSAScript(script)
    }

    static func copyCommand(_ event: CommandEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(event.copyText, forType: .string)
    }

    static func copySessionId(_ event: CommandEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(event.sessionId, forType: .string)
    }

    static func revealTranscript(_ event: CommandEvent) {
        let url = URL(fileURLWithPath: event.transcriptPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Shell / AppleScript safety

    /// Single-quote a string for POSIX shells, escaping embedded single quotes.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for inclusion inside an AppleScript double-quoted literal.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runOSAScript(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        do {
            try process.run()
        } catch {
            NSSound.beep()
        }
    }
}
