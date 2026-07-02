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
    @StateObject private var claudeStore: TranscriptStore
    @StateObject private var codexStore: TranscriptStore
    @StateObject private var settings: SettingsStore
    @StateObject private var availability = SourceAvailability()
    @StateObject private var updater = UpdaterViewModel()
    private let engine = NotificationEngine()

    init() {
        let claudeStore = TranscriptStore(scanner: EventScanner(source: .claude))
        let codexStore = TranscriptStore(scanner: EventScanner(source: .codex))
        let settings = SettingsStore()
        _claudeStore = StateObject(wrappedValue: claudeStore)
        _codexStore = StateObject(wrappedValue: codexStore)
        _settings = StateObject(wrappedValue: settings)

        // Wire settings → engine and the live feed → engine.
        engine.updateConfig(settings.snapshot())
        let engine = self.engine
        settings.onChange = { [weak settings] in
            guard let settings else { return }
            engine.updateConfig(settings.snapshot())
        }
        claudeStore.onActivity = { events, done in
            engine.process(events: events, doneSessions: done)
        }
        codexStore.onActivity = { events, done in
            engine.process(events: events, doneSessions: done)
        }

        SystemNotifier.requestAuthorization()
        availability.start()
        claudeStore.start()
        codexStore.start()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: sourceInsertedBinding(.claude)) {
            MenuContentView(openSettings: {
                SettingsWindowController.shared.show(settings: settings, store: claudeStore, engine: engine, updater: updater)
            })
                .environmentObject(claudeStore)
                .environmentObject(settings)
                .frame(width: 460, height: 560)
        } label: {
            // Reflect the busiest session: a waiting session (needs you) shows a badge.
            Image(systemName: menuBarSymbol(for: claudeStore, fallback: "sparkles"))
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: sourceInsertedBinding(.codex)) {
            MenuContentView(source: .codex, openSettings: {
                SettingsWindowController.shared.show(settings: settings, store: codexStore, engine: engine, updater: updater)
            })
                .environmentObject(codexStore)
                .environmentObject(settings)
                .frame(width: 460, height: 560)
        } label: {
            Image(systemName: menuBarSymbol(for: codexStore, fallback: "chevron.left.forwardslash.chevron.right"))
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: fallbackInsertedBinding) {
            EmptySourcesView(
                showSettings: {
                    SettingsWindowController.shared.show(settings: settings, store: claudeStore, engine: engine, updater: updater)
                },
                refresh: { availability.refresh() }
            )
            .frame(width: 360, height: 220)
        } label: {
            Image(systemName: "sparkle.magnifyingglass")
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarSymbol(for store: TranscriptStore, fallback: String) -> String {
        if store.sessions.contains(where: { $0.state == .waiting }) { return "bell.badge" }
        return fallback
    }

    private func isVisible(_ source: TranscriptSource) -> Bool {
        let mode = source == .claude ? settings.claudeVisibility : settings.codexVisibility
        switch mode {
        case .automatic:
            return availability.hasTranscripts(for: source)
        case .show:
            return true
        case .hide:
            return false
        }
    }

    private func sourceInsertedBinding(_ source: TranscriptSource) -> Binding<Bool> {
        Binding(
            get: { isVisible(source) },
            set: { inserted in
                if !inserted {
                    if source == .claude { settings.claudeVisibility = .hide }
                    else { settings.codexVisibility = .hide }
                }
            }
        )
    }

    private var fallbackInsertedBinding: Binding<Bool> {
        Binding(
            get: { !isVisible(.claude) && !isVisible(.codex) },
            set: { _ in }
        )
    }
}
