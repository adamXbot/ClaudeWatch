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
    @StateObject private var settings: SettingsStore
    @StateObject private var updater = UpdaterViewModel()
    private let engine = NotificationEngine()

    init() {
        let store = TranscriptStore()
        let settings = SettingsStore()
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)

        // Wire settings → engine and the live feed → engine.
        engine.updateConfig(settings.snapshot())
        let engine = self.engine
        settings.onChange = { [weak settings] in
            guard let settings else { return }
            engine.updateConfig(settings.snapshot())
        }
        store.onActivity = { events, done in
            engine.process(events: events, doneSessions: done)
        }

        SystemNotifier.requestAuthorization()
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(openSettings: {
                SettingsWindowController.shared.show(settings: settings, store: store, engine: engine, updater: updater)
            })
                .environmentObject(store)
                .environmentObject(settings)
                .frame(width: 460, height: 560)
        } label: {
            // Reflect the busiest session: a waiting session (needs you) shows a badge.
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if store.sessions.contains(where: { $0.state == .waiting }) { return "bell.badge" }
        return "sparkles"
    }
}
