import AppKit
import SwiftUI
import ClaudeWatchCore

/// Lazily creates and shows the Settings window (a MenuBarExtra app has no standard one).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(settings: SettingsStore, store: TranscriptStore, engine: NotificationEngine) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView(engine: engine)
            .environmentObject(settings)
            .environmentObject(store)
        let hosting = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: hosting)
        w.title = "ClaudeWatch Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 580, height: 540))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
