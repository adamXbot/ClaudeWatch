import XCTest
import Combine
@testable import ClaudeWatchCore

/// What a launch tells the notification rules, wired the way `ClaudeWatchApp` wires it: the
/// settings decide whether a store starts, and the store's activity goes to the engine.
final class LaunchNotificationTests: XCTestCase {

    /// Stands in for `NotificationEngine`: matches rules as it does, and records what it
    /// would have sent instead of posting a notification or calling a webhook.
    private final class FakeEngine {
        private let lock = NSLock()
        private let rules: [NotificationRule]
        private var sent: [String] = []

        init(rules: [NotificationRule]) { self.rules = rules }

        func process(events: [CommandEvent], doneSessions: [SessionStatus]) {
            lock.lock(); defer { lock.unlock() }
            for event in events {
                for rule in rules where rule.matches(event: event) {
                    sent.append("\(rule.name): \(event.id)")
                }
            }
            for done in doneSessions {
                for rule in rules where rule.matchesSessionDone(project: done.projectName) {
                    sent.append("\(rule.name): session \(done.id)")
                }
            }
        }

        var dispatched: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    }

    /// The source this test does not look at.
    private final class Unwatched: ScanControl {
        func start(announceBacklog: Bool) {}
        func stop() {}
    }

    private var fixtures: TranscriptFixtures!
    private var store: TranscriptStore!
    private var watcher: ManualWatcher!
    private var demand: ScanDemand?
    private let commits = NotificationRule(name: "Commits", trigger: .action, kind: .shell, textMatch: "git commit")

    override func setUpWithError() throws {
        fixtures = try TranscriptFixtures()
    }

    override func tearDown() {
        demand = nil
        store?.stop()
        store?.onScanQueue {}
        store = nil
        fixtures.remove()
    }

    /// Starts a store as the app does at launch, with `rules` already in the settings.
    private func launch(rules: [NotificationRule]) -> FakeEngine {
        let settings = SettingsStore(defaults: MemoryDefaults())
        settings.claudeVisibility = .hide       // the rule alone keeps the source scanning
        settings.codexVisibility = .hide
        settings.rules = rules
        let menuBar = MenuBarInsertion(
            settings: settings, hasClaude: CurrentValueSubject(false), hasCodex: CurrentValueSubject(false)
        )

        let engine = FakeEngine(rules: rules)
        watcher = ManualWatcher()
        store = TranscriptStore(scanner: EventScanner(source: .claude, root: fixtures.root), interval: 0.02, watcher: watcher)
        store.onActivity = { events, done in
            engine.process(events: events, doneSessions: done)
        }
        demand = ScanDemand(settings: settings, menuBar: menuBar, claude: store, codex: Unwatched())
        return engine
    }

    private func bash(_ command: String, id: String, at date: Date) -> String {
        TranscriptFixtures.bash(command, id: id, at: date) + "\n"
    }

    func testLaunchDoesNotNotifyForWhatHappenedBeforeIt() throws {
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        let file = try fixtures.append(bash("git commit -m 'then'", id: "old", at: twoDaysAgo),
                                       to: "p/a.jsonl", modified: twoDaysAgo)

        let engine = launch(rules: [commits])
        waitUntil("the feed is loaded") { store.events.count == 1 }
        store.onScanQueue {}
        XCTAssertEqual(store.events.map(\.id), ["old"], "history is shown")
        XCTAssertEqual(engine.dispatched, [], "and is not news to a rule")

        try fixtures.append(bash("git commit -m 'now'", id: "new", at: Date()), to: "p/a.jsonl")
        watcher.report([file.path])
        waitUntil("the append is shown") { store.events.count == 2 }
        store.onScanQueue {}
        XCTAssertEqual(engine.dispatched, ["Commits: new"], "what happens after launch is")
    }
}
