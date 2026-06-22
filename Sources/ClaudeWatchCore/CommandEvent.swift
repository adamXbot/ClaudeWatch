import Foundation

/// A single system-touching action extracted from a Claude Code transcript.
/// `id` is the tool_use id (e.g. "toolu_…"), which is globally unique and stable,
/// so it doubles as the dedupe key and the in-page anchor for the browser view.
public struct CommandEvent: Identifiable, Hashable {
    public let id: String              // tool_use id
    public let kind: EventKind
    public let toolName: String        // raw tool name (Bash, Write, …)
    public let primary: String         // headline: command / path / url / query
    public let secondary: String?      // supporting detail: description / edit mode / prompt
    public let sessionId: String       // the thread that issued this command
    public let cwd: String             // project working directory
    public let projectName: String     // display name (last path component of cwd)
    public let timestamp: Date
    public let isSubagent: Bool        // issued by a subagent / workflow run, not the main thread
    public let gitBranch: String?
    public let transcriptPath: String  // absolute path to the .jsonl that contains this event

    public init(
        id: String, kind: EventKind, toolName: String, primary: String, secondary: String?,
        sessionId: String, cwd: String, projectName: String, timestamp: Date,
        isSubagent: Bool, gitBranch: String?, transcriptPath: String
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.primary = primary
        self.secondary = secondary
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName
        self.timestamp = timestamp
        self.isSubagent = isSubagent
        self.gitBranch = gitBranch
        self.transcriptPath = transcriptPath
    }

    /// Text placed on the clipboard by the "Copy" action.
    public var copyText: String { primary }
}
