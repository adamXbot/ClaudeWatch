import Foundation

/// Live state of a Claude Code session.
public enum SessionActivityState: String, Codable, Hashable {
    case working   // a tool is running / actively streaming   → blue dot
    case waiting   // turn ended or idle — awaiting you         → yellow dot
}

/// A snapshot of one session's current activity, shown in the "Active sessions" strip.
public struct SessionStatus: Identifiable, Hashable {
    public let id: String            // sessionId
    public let projectName: String
    public let cwd: String
    public let transcriptPath: String
    public let state: SessionActivityState
    public let statusText: String    // e.g. "running: swift test" / "awaiting you" / "idle 3m"
    public let lastActivity: Date

    public init(
        id: String, projectName: String, cwd: String, transcriptPath: String,
        state: SessionActivityState, statusText: String, lastActivity: Date
    ) {
        self.id = id
        self.projectName = projectName
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.state = state
        self.statusText = statusText
        self.lastActivity = lastActivity
    }
}
