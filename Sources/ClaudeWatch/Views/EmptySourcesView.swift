import SwiftUI

struct EmptySourcesView: View {
    let showSettings: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No AI activity sources found")
                .font(.system(size: 14, weight: .semibold))
            Text("ClaudeWatch looks for Claude transcripts in ~/.claude and Codex sessions in ~/.codex. You can also force either menu icon on in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh") { refresh() }
                Button("Settings") { showSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
    }
}
