import XCTest
@testable import ClaudeWatchCore

final class NotificationRuleTests: XCTestCase {

    private func event(kind: EventKind, primary: String, project: String = "proj") -> CommandEvent {
        CommandEvent(
            id: UUID().uuidString, kind: kind, toolName: "X", primary: primary, secondary: nil,
            sessionId: "s", cwd: "/\(project)", projectName: project, timestamp: Date(),
            isSubagent: false, gitBranch: nil, transcriptPath: "/t.jsonl"
        )
    }

    func testGitCommitRuleMatchesOnlyMatchingShell() {
        let rule = NotificationRule(name: "Commits", trigger: .action, kind: .shell, textMatch: "git commit")
        XCTAssertTrue(rule.matches(event: event(kind: .shell, primary: "git commit -m 'x'")))
        XCTAssertFalse(rule.matches(event: event(kind: .shell, primary: "git status")))
        XCTAssertFalse(rule.matches(event: event(kind: .fileWrite, primary: "git commit")))   // wrong kind
    }

    func testAnyKindAndAnyTextMatchesAllActions() {
        let rule = NotificationRule(name: "All", trigger: .action, kind: nil, textMatch: "")
        XCTAssertTrue(rule.matches(event: event(kind: .webSearch, primary: "anything")))
    }

    func testRegexMatch() {
        let rule = NotificationRule(name: "re", trigger: .action, kind: .shell,
                                    textMatch: #"git (push|commit)"#, useRegex: true)
        XCTAssertTrue(rule.matches(event: event(kind: .shell, primary: "git push origin main")))
        XCTAssertFalse(rule.matches(event: event(kind: .shell, primary: "git pull")))
    }

    func testProjectScope() {
        let rule = NotificationRule(name: "scoped", trigger: .action, kind: nil,
                                    scope: ProjectScope(allProjects: false, projects: ["alpha"]))
        XCTAssertTrue(rule.matches(event: event(kind: .shell, primary: "x", project: "alpha")))
        XCTAssertFalse(rule.matches(event: event(kind: .shell, primary: "x", project: "beta")))
    }

    func testSessionDoneRule() {
        let rule = NotificationRule(name: "done", trigger: .sessionDone)
        XCTAssertTrue(rule.matchesSessionDone(project: "anything"))
        XCTAssertFalse(rule.matches(event: event(kind: .shell, primary: "x")))  // not an action rule
        // disabled
        var off = rule; off.isEnabled = false
        XCTAssertFalse(off.matchesSessionDone(project: "x"))
    }

    func testDisabledRuleNeverMatches() {
        var rule = NotificationRule(name: "x", trigger: .action)
        rule.isEnabled = false
        XCTAssertFalse(rule.matches(event: event(kind: .shell, primary: "x")))
    }

    func testWebhookPayloadShapes() {
        func body(_ p: WebhookProvider) -> [String: Any] {
            try! JSONSerialization.jsonObject(with: NotificationEngine.payload(provider: p, text: "hi")) as! [String: Any]
        }
        XCTAssertEqual(body(.discord)["content"] as? String, "hi")
        XCTAssertEqual(body(.slack)["text"] as? String, "hi")
        XCTAssertEqual(body(.generic)["text"] as? String, "hi")
        XCTAssertEqual(body(.teams)["@type"] as? String, "MessageCard")
        XCTAssertEqual(body(.teams)["text"] as? String, "hi")
    }
}

final class SettingsStoreTests: XCTestCase {

    func testRulesRoundTripThroughUserDefaults() {
        let suite = "claudewatch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.rules = [NotificationRule(name: "Commits", trigger: .action, kind: .shell, textMatch: "git commit")]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.rules.count, 1)
        XCTAssertEqual(reloaded.rules.first?.name, "Commits")
        XCTAssertEqual(reloaded.rules.first?.kind, .shell)
    }

    func testSnapshotReflectsSystemToggle() {
        let suite = "claudewatch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.systemNotificationsEnabled = false
        XCTAssertFalse(store.snapshot().systemEnabled)
    }
}
