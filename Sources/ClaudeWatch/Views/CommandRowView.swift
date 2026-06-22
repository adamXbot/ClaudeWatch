import SwiftUI
import ClaudeWatchCore

struct CommandRowView: View {
    let event: CommandEvent
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(kindColor)
                .frame(width: 20, height: 20)
                .background(kindColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.primary)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(event.projectName)
                        .foregroundStyle(.secondary)
                    if let s = event.secondary, !s.isEmpty {
                        Text("· \(s)")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if event.isSubagent {
                        Text("subagent")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
                .font(.system(size: 10.5))
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text(RelativeTime.string(from: event.timestamp))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if hovering {
                    HStack(spacing: 8) {
                        actionButton("globe", help: "View thread in browser") { Actions.openInBrowser(event) }
                        actionButton("terminal", help: "Resume in Claude Code") { Actions.resumeInClaudeCode(event) }
                        actionButton("doc.on.doc", help: "Copy command") { Actions.copyCommand(event) }
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Actions.openInBrowser(event) }
        .contextMenu {
            Button("View thread in browser") { Actions.openInBrowser(event) }
            Button("Resume in Claude Code") { Actions.resumeInClaudeCode(event) }
            Divider()
            Button("Copy command") { Actions.copyCommand(event) }
            Button("Copy session id") { Actions.copySessionId(event) }
            Button("Reveal transcript in Finder") { Actions.revealTranscript(event) }
        }
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var kindColor: Color {
        switch event.kind {
        case .shell:        return .orange
        case .fileWrite:    return .green
        case .fileEdit:     return .blue
        case .notebookEdit: return .purple
        case .webFetch:     return .teal
        case .webSearch:    return .teal
        }
    }
}
