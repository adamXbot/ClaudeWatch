import XCTest
import Combine
@testable import ClaudeWatchCore

final class ISOTimestampTests: XCTestCase {

    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func reference(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }

    func testFastPathAgreesWithTheFormatterExactly() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            // Anywhere from 1970 to 2100, to the millisecond.
            let millis = Int64.random(in: 0..<4_102_444_800_000, using: &generator)
            let date = Date(timeIntervalSince1970: Double(millis) / 1000)
            for text in [fractional.string(from: date), plain.string(from: date)] {
                guard let fast = ISOTimestamp.fast(text) else { return XCTFail("no fast path for \(text)") }
                XCTAssertEqual(fast, reference(text), text)
            }
        }
    }

    func testCalendarEdges() {
        for text in [
            "1970-01-01T00:00:00.000Z", "2000-02-29T23:59:59.999Z", "2024-02-29T12:00:00Z",
            "2026-06-22T01:14:40.425Z", "2026-12-31T23:59:59Z", "2100-03-01T00:00:00.001Z",
        ] {
            XCTAssertNotNil(ISOTimestamp.fast(text), text)
            XCTAssertEqual(ISOTimestamp.date(from: text), reference(text), text)
        }
    }

    func testOtherShapesFallBackToTheFormatter() {
        for text in [
            "2026-06-22T11:14:40.425+10:00",    // an offset instead of Z
            "2026-06-22T01:14:40.425123Z",      // microseconds
            "2026-06-22T01:14:40+00:00",
            "2026-02-30T01:14:40.425Z",         // no such day
            "2026-06-22T24:00:00Z",
            "2026-06-22 01:14:40Z",
            "not a date", "",
        ] {
            XCTAssertNil(ISOTimestamp.fast(text), text)
            XCTAssertEqual(ISOTimestamp.date(from: text), reference(text), text)
        }
    }
}

final class LineMarkersTests: XCTestCase {

    private func match(_ markers: LineMarkers, _ line: String) -> Bool {
        Array(line.utf8).withUnsafeBytes { markers.match($0) }
    }

    func testFindsAnyMarkerAnywhere() {
        let markers = LineMarkers([#""exec_command""#, #""apply_patch""#])
        XCTAssertTrue(match(markers, #""exec_command""#))
        XCTAssertTrue(match(markers, #"{"name":"apply_patch","x":1}"#))
        XCTAssertTrue(match(markers, #"some_other_keys_first {"name":"exec_command"}"#))
        XCTAssertTrue(match(markers, #"…"apply_patch""#))
    }

    func testIgnoresLookalikes() {
        let markers = LineMarkers([#""tool_use""#])
        XCTAssertFalse(match(markers, ""))
        XCTAssertFalse(match(markers, "no underscore here"))
        XCTAssertFalse(match(markers, #"{"type":"tool_result","tool_use_id":"t1"}"#))
        XCTAssertFalse(match(markers, #"prose about tool_use without quotes"#))
        XCTAssertFalse(match(markers, #""tool_us"#), "cut off at the end of the line")
        XCTAssertFalse(match(markers, #"_use""#), "cut off at the start of the line")
    }
}

final class ScanDemandTests: XCTestCase {

    private final class Recorder: ScanControl {
        var calls: [String] = []
        func start() { calls.append("start") }
        func stop() { calls.append("stop") }
    }

    private var settings: SettingsStore!
    private var hasClaude: CurrentValueSubject<Bool, Never>!
    private var hasCodex: CurrentValueSubject<Bool, Never>!

    override func setUp() {
        settings = SettingsStore(defaults: MemoryDefaults())
        hasClaude = CurrentValueSubject(false)
        hasCodex = CurrentValueSubject(false)
    }

    private func makeDemand(claude: Recorder, codex: Recorder) -> ScanDemand {
        let menuBar = MenuBarInsertion(settings: settings, hasClaude: hasClaude, hasCodex: hasCodex)
        return ScanDemand(settings: settings, menuBar: menuBar, claude: claude, codex: codex)
    }

    func testNeededForAnIconOrAnEnabledRule() {
        let enabled = NotificationRule(name: "on", trigger: .sessionDone)
        let disabled = NotificationRule(name: "off", isEnabled: false)
        XCTAssertFalse(ScanDemand.isNeeded(iconInserted: false, rules: []))
        XCTAssertFalse(ScanDemand.isNeeded(iconInserted: false, rules: [disabled]))
        XCTAssertTrue(ScanDemand.isNeeded(iconInserted: true, rules: []))
        XCTAssertTrue(ScanDemand.isNeeded(iconInserted: false, rules: [disabled, enabled]))
    }

    func testHiddenSourceWithoutRulesIsNeverStarted() {
        settings.claudeVisibility = .show
        settings.codexVisibility = .hide
        let claude = Recorder(), codex = Recorder()
        let demand = makeDemand(claude: claude, codex: codex)

        XCTAssertEqual(claude.calls, ["start"], "shown at launch: starts")
        XCTAssertEqual(codex.calls, ["stop"], "hidden with no rules: not scanned")
        withExtendedLifetime(demand) {}
    }

    func testRulePresentAtLaunchStartsHiddenSourcesToo() {
        settings.claudeVisibility = .hide
        settings.codexVisibility = .hide
        settings.rules = [NotificationRule(name: "done", trigger: .sessionDone)]
        let claude = Recorder(), codex = Recorder()
        let demand = makeDemand(claude: claude, codex: codex)

        XCTAssertEqual(claude.calls, ["start"])
        XCTAssertEqual(codex.calls, ["start"])
        withExtendedLifetime(demand) {}
    }

    func testBecomingNeededLaterStartsAndStopsAgain() {
        settings.claudeVisibility = .automatic
        settings.codexVisibility = .hide
        let claude = Recorder(), codex = Recorder()
        let demand = makeDemand(claude: claude, codex: codex)
        XCTAssertEqual(claude.calls, ["stop"])

        hasClaude.send(true)                        // transcripts found: the icon appears
        XCTAssertEqual(claude.calls, ["stop", "start"])

        settings.rules = [NotificationRule(name: "done", trigger: .sessionDone)]
        XCTAssertEqual(claude.calls, ["stop", "start"], "already running")
        XCTAssertEqual(codex.calls, ["stop", "start"], "a rule needs the hidden source as well")

        settings.rules[0].isEnabled = false
        XCTAssertEqual(codex.calls, ["stop", "start", "stop"])
        XCTAssertEqual(claude.calls, ["stop", "start"], "still shown")

        settings.claudeVisibility = .hide
        XCTAssertEqual(claude.calls, ["stop", "start", "stop"])
        withExtendedLifetime(demand) {}
    }
}
