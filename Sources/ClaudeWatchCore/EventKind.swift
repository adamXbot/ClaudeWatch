import Foundation

/// The category of a system-touching action the AI performed.
/// Read-only tools (Read/Grep/Glob/Task/etc.) are intentionally excluded —
/// this feed is about what the AI *does* to the machine, not what it looks at.
public enum EventKind: String, CaseIterable, Codable, Hashable {
    case shell          // Bash
    case fileWrite      // Write
    case fileEdit       // Edit / MultiEdit
    case notebookEdit   // NotebookEdit
    case webFetch       // WebFetch
    case webSearch      // WebSearch

    /// Short human label used in the UI and the headless dump.
    public var label: String {
        switch self {
        case .shell:        return "Shell"
        case .fileWrite:    return "Write"
        case .fileEdit:     return "Edit"
        case .notebookEdit: return "Notebook"
        case .webFetch:     return "Fetch"
        case .webSearch:    return "Search"
        }
    }

    /// SF Symbol used for the row icon.
    public var symbol: String {
        switch self {
        case .shell:        return "terminal"
        case .fileWrite:    return "doc.badge.plus"
        case .fileEdit:     return "pencil"
        case .notebookEdit: return "book"
        case .webFetch:     return "arrow.down.circle"
        case .webSearch:    return "magnifyingglass"
        }
    }
}
