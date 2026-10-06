import SwiftUI

/// The popover behind the fallback menu bar item, shown while neither source has an
/// icon, so Settings stays reachable.
struct EmptySourcesView: View {
    let app: SurfaceApp
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SurfacePopoverHeader(app: app, mark: Image(systemName: "sparkles"))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
            Divider()
            VStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No AI activity sources found")
                    .font(.system(size: 14, weight: .semibold))
                Text("ClaudeWatch looks for Claude transcripts in ~/.claude and Codex sessions in ~/.codex. You can also keep either menu bar icon on in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh") { refresh() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SurfacePopoverFooter(app: app)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}
