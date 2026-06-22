import SwiftUI
import ClaudeWatchCore

/// Compact strip of recently-active sessions with a working (blue) / waiting (yellow) dot.
struct ActiveSessionsView: View {
    let sessions: [SessionStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACTIVE SESSIONS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)

            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.state == .working ? Color.blue : Color.yellow)
                        .frame(width: 8, height: 8)
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(session.statusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if session.state == .waiting {
                        Button { Actions.resume(sessionId: session.id, cwd: session.cwd) } label: {
                            Image(systemName: "arrow.uturn.left.circle").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help("Resume in Claude Code")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { Actions.openThreadInBrowser(transcriptPath: session.transcriptPath) }
                .help("\(session.projectName) · \(session.statusText)")
            }
        }
        .padding(.bottom, 4)
        .background(Color.primary.opacity(0.04))
    }
}
