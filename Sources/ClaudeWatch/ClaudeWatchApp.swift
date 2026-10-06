import SwiftUI
import AppKit
import Sparkle
import ClaudeWatchCore

struct ClaudeWatchApp: App {
    @StateObject private var claudeStore: TranscriptStore
    @StateObject private var codexStore: TranscriptStore
    @StateObject private var menuBar: MenuBarInsertion
    @StateObject private var updates: SurfaceUpdates
    // Deliberately not observed here: the scenes re-render for `menuBar`, never for a
    // settings or availability publish (see `MenuBarInsertion`).
    private let settings: SettingsStore
    private let availability: SourceAvailability
    private let demand: ScanDemand
    private let engine = NotificationEngine()
    /// Sparkle's standard updater. The shared Updates pane and Check for Updates… drive it
    /// through `updates`; automatic checks stay off until the user turns them on
    /// (`SUEnableAutomaticChecks` is false in the Info.plist that build.sh writes).
    private let updater: SPUStandardUpdaterController

    private let app = ClaudeWatchSurface.app
    private let help = ClaudeWatchSurface.help

    init() {
        let claudeStore = TranscriptStore(scanner: EventScanner(source: .claude))
        let codexStore = TranscriptStore(scanner: EventScanner(source: .codex))
        let settings = SettingsStore()
        let availability = SourceAvailability()
        let menuBar = MenuBarInsertion(
            settings: settings, hasClaude: availability.$hasClaude, hasCodex: availability.$hasCodex
        )
        let updater = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        _claudeStore = StateObject(wrappedValue: claudeStore)
        _codexStore = StateObject(wrappedValue: codexStore)
        _menuBar = StateObject(wrappedValue: menuBar)
        _updates = StateObject(wrappedValue: SurfaceUpdates(
            driver: updater.updater, releaseNotes: ClaudeWatchSurface.releaseNotes
        ))
        self.settings = settings
        self.availability = availability
        self.updater = updater

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
        // Starts each store now if it is needed, and whenever that changes.
        demand = ScanDemand(settings: settings, menuBar: menuBar, claude: claudeStore, codex: codexStore)

        // A menu bar utility (LSUIElement): it joins the Dock, with a main menu, only while
        // one of its windows is open, and leaves again when the last one closes.
        SurfaceActivation.shared.start()
    }

    var body: some Scene {
        // The menu bar items come first: SwiftUI presents the first scene at launch, and
        // with Settings there it would open the Settings window every time the app starts.
        MenuBarExtra(isInserted: sourceInsertedBinding(.claude)) {
            MenuContentView(app: app, source: .claude)
                .environmentObject(claudeStore)
                .frame(width: 460, height: 560)
        } label: {
            // Reflect the busiest session: a waiting session (needs you) shows a badge.
            Image(systemName: menuBarSymbol(for: claudeStore, fallback: "sparkles"))
                .accessibilityLabel(menuBarLabel(for: claudeStore, source: .claude))
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: sourceInsertedBinding(.codex)) {
            MenuContentView(app: app, source: .codex)
                .environmentObject(codexStore)
                .frame(width: 460, height: 560)
        } label: {
            Image(systemName: menuBarSymbol(for: codexStore, fallback: "chevron.left.forwardslash.chevron.right"))
                .accessibilityLabel(menuBarLabel(for: codexStore, source: .codex))
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: fallbackInsertedBinding) {
            EmptySourcesView(app: app, refresh: { availability.refresh() })
                .frame(width: 360, height: 300)
        } label: {
            Image(systemName: "sparkle.magnifyingglass")
                .accessibilityLabel("ClaudeWatch, no activity sources found")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SurfaceSettings(app: app, panes: panes)
        }
        .commands {
            SurfaceCommands(app: app, help: help, updates: updates)
        }

        SurfaceAboutWindow(app: app, help: help)
        SurfaceManualWindow(app: app)
        SurfaceShortcutsWindow(groups: ClaudeWatchSurface.shortcuts)
    }

    /// General first, Updates last; the scaffold adds the About button to General.
    private var panes: [SurfacePane] {
        [
            SurfacePane("General", systemImage: "gearshape") {
                GeneralPane(app: app, settings: settings)
            },
            SurfacePane("Rules", systemImage: "bell.badge") {
                RulesPane(settings: settings, claudeStore: claudeStore, codexStore: codexStore)
            },
            SurfacePane("Webhooks", systemImage: "link") {
                WebhooksPane(settings: settings, engine: engine)
            },
            .updates(updates),
        ]
    }

    private func menuBarSymbol(for store: TranscriptStore, fallback: String) -> String {
        if store.sessions.contains(where: { $0.state == .waiting }) { return "bell.badge" }
        return fallback
    }

    private func menuBarLabel(for store: TranscriptStore, source: TranscriptSource) -> String {
        if store.sessions.contains(where: { $0.state == .waiting }) {
            return "\(source.displayName) activity, a session is waiting for you"
        }
        return "\(source.displayName) activity"
    }

    private func sourceInsertedBinding(_ source: TranscriptSource) -> Binding<Bool> {
        Binding(
            get: { menuBar.isInserted(source) },
            set: { menuBar.report(source, inserted: $0) }
        )
    }

    private var fallbackInsertedBinding: Binding<Bool> {
        Binding(
            get: { menuBar.fallback },
            set: { _ in }
        )
    }
}
