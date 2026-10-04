import XCTest
import Combine
@testable import ClaudeWatchCore

final class MenuBarInsertionTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var hasClaude: CurrentValueSubject<Bool, Never>!
    private var hasCodex: CurrentValueSubject<Bool, Never>!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        suite = "claudewatch.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
        hasClaude = CurrentValueSubject(false)
        hasCodex = CurrentValueSubject(false)
    }

    override func tearDown() {
        cancellables.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeInsertion(claude: SourceVisibility, codex: SourceVisibility) -> MenuBarInsertion {
        settings.claudeVisibility = claude
        settings.codexVisibility = codex
        return MenuBarInsertion(settings: settings, hasClaude: hasClaude, hasCodex: hasCodex)
    }

    /// Lets the deferred half of `report` run.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testAutomaticFollowsTranscripts() {
        let insertion = makeInsertion(claude: .automatic, codex: .automatic)
        XCTAssertFalse(insertion.claude)
        XCTAssertFalse(insertion.codex)
        XCTAssertTrue(insertion.fallback)

        hasClaude.send(true)
        XCTAssertTrue(insertion.claude)
        XCTAssertFalse(insertion.codex)
        XCTAssertFalse(insertion.fallback)

        hasClaude.send(false)
        XCTAssertTrue(insertion.fallback)
    }

    func testShowAndHideOverrideTranscripts() {
        hasCodex.send(true)
        let insertion = makeInsertion(claude: .show, codex: .hide)
        XCTAssertTrue(insertion.claude)      // shown with no transcripts
        XCTAssertFalse(insertion.codex)      // hidden despite transcripts

        settings.claudeVisibility = .hide
        settings.codexVisibility = .automatic
        XCTAssertFalse(insertion.claude)
        XCTAssertTrue(insertion.codex)
    }

    /// The render loop: SwiftUI echoes each extra's state on every scene update. An echo
    /// must not publish (that is what invalidated the App) or rewrite the settings.
    func testEchoedReportsNeverPublishOrWrite() {
        hasCodex.send(true)
        let insertion = makeInsertion(claude: .hide, codex: .automatic)
        var publishes = 0
        insertion.objectWillChange.sink { publishes += 1 }.store(in: &cancellables)
        settings.objectWillChange.sink { publishes += 1 }.store(in: &cancellables)
        var settingsWrites = 0
        settings.onChange = { settingsWrites += 1 }

        for _ in 0..<1000 {
            insertion.report(.claude, inserted: false)
            insertion.report(.codex, inserted: true)
        }
        drainMainQueue()

        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(settingsWrites, 0)
        XCTAssertEqual(settings.claudeVisibility, .hide)
        XCTAssertEqual(settings.codexVisibility, .automatic)
    }

    /// An automatic icon that is absent for lack of transcripts stays automatic.
    func testEchoDoesNotTurnAutomaticIntoHide() {
        let insertion = makeInsertion(claude: .automatic, codex: .automatic)
        insertion.report(.claude, inserted: false)
        insertion.report(.codex, inserted: false)
        drainMainQueue()

        XCTAssertEqual(settings.claudeVisibility, .automatic)
        XCTAssertEqual(settings.codexVisibility, .automatic)
    }

    /// Dragging an icon out of the menu bar is the one report that changes anything.
    func testRemovalByTheUserBecomesHide() {
        let insertion = makeInsertion(claude: .show, codex: .show)
        insertion.report(.claude, inserted: false)
        XCTAssertEqual(settings.claudeVisibility, .show)   // deferred, not inside the update

        drainMainQueue()
        XCTAssertEqual(settings.claudeVisibility, .hide)
        XCTAssertFalse(insertion.claude)
        XCTAssertEqual(settings.codexVisibility, .show)
        XCTAssertEqual(SettingsStore(defaults: defaults).claudeVisibility, .hide)   // persisted
    }

    func testFallbackOnlyWhenBothAreAbsent() {
        let insertion = makeInsertion(claude: .hide, codex: .hide)
        XCTAssertTrue(insertion.fallback)
        settings.codexVisibility = .show
        XCTAssertFalse(insertion.fallback)
        settings.codexVisibility = .hide
        XCTAssertTrue(insertion.fallback)
    }
}
