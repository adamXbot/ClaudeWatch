import SwiftUI
import AppKit
import ClaudeWatchCore

/// Hides the Dock icon so the app lives purely in the menu bar.
/// (Belt-and-suspenders with LSUIElement in the bundle's Info.plist.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct ClaudeWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: TranscriptStore

    init() {
        let store = TranscriptStore()
        _store = StateObject(wrappedValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .frame(width: 460, height: 560)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
