import Foundation

public enum TranscriptSource: String, Codable, Hashable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    public var activityTitle: String {
        switch self {
        case .claude: return "Claude activity"
        case .codex: return "Codex activity"
        }
    }

    public var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .codex:
            return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    public var watchedPathLabel: String {
        switch self {
        case .claude: return "~/.claude"
        case .codex: return "~/.codex"
        }
    }
}

public enum SourceVisibility: String, Codable, Hashable, CaseIterable {
    case automatic
    case show
    case hide

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .show: return "Show"
        case .hide: return "Hide"
        }
    }
}
