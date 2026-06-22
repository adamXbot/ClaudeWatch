import Foundation
import Combine

/// Owns the live event feed and per-session status. All file scanning and tracking
/// happens on a private serial queue; only published snapshots cross to the main thread.
public final class TranscriptStore: ObservableObject {

    /// Newest-first event feed, capped to `maxEvents`. Read on the main thread by the UI.
    @Published public private(set) var events: [CommandEvent] = []
    /// Recently-active sessions with their working/waiting state.
    @Published public private(set) var sessions: [SessionStatus] = []
    @Published public private(set) var isLoading = true
    @Published public var isPaused = false {
        didSet { let v = isPaused; queue.async { self.paused = v } }
    }

    /// Called on the scan queue whenever new events arrive or sessions finish. The app
    /// routes this into the notification engine. Either array may be empty.
    public var onActivity: ((_ newEvents: [CommandEvent], _ doneSessions: [SessionStatus]) -> Void)?

    private let scanner: EventScanner
    private let tracker: SessionTracker
    private let queue = DispatchQueue(label: "io.github.adamxbot.claudewatch.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval

    // Touched only on `queue`.
    private var offsets: [String: UInt64] = [:]
    private var seen: Set<String> = []
    private var accumulated: [CommandEvent] = []
    private var paused = false
    private var loadingCleared = false
    private let maxEvents = 2000

    public init(
        scanner: EventScanner = EventScanner(),
        tracker: SessionTracker = SessionTracker(),
        interval: TimeInterval = 1.0
    ) {
        self.scanner = scanner
        self.tracker = tracker
        self.interval = interval
    }

    /// Begin watching. Safe to call once at app launch.
    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Force a re-read from scratch (used by the manual refresh button).
    public func refresh() {
        queue.async {
            self.offsets.removeAll()
            self.seen.removeAll()
            self.accumulated.removeAll()
            self.tickBody(force: true)
        }
    }

    // MARK: - Scanning (runs on `queue`)

    private func tick() {
        if paused { return }
        tickBody(force: false)
    }

    private func tickBody(force: Bool) {
        let now = Date()

        var fresh: [CommandEvent] = []
        scanner.scanDelta(offsets: &offsets) { [tracker] line, path in
            fresh.append(contentsOf: TranscriptParser.events(fromLine: line, transcriptPath: path))
            tracker.ingest(line: line, path: path)
        }

        var addedEvents: [CommandEvent] = []
        for event in fresh where !seen.contains(event.id) {
            seen.insert(event.id)
            accumulated.append(event)
            addedEvents.append(event)
        }
        let added = !addedEvents.isEmpty
        if added {
            accumulated.sort { $0.timestamp > $1.timestamp }
            if accumulated.count > maxEvents {
                for e in accumulated[maxEvents...] { seen.remove(e.id) }
                accumulated.removeLast(accumulated.count - maxEvents)
            }
        }

        // Sessions are time-dependent, so recompute every tick.
        let sessionSnapshot = tracker.snapshot(now: now)
        let done = tracker.drainDone()

        let eventsSnapshot = accumulated
        let clearedLoading = !loadingCleared
        loadingCleared = true

        DispatchQueue.main.async {
            if added { self.events = eventsSnapshot }
            if self.sessions != sessionSnapshot { self.sessions = sessionSnapshot }
            if clearedLoading || added { self.isLoading = false }
        }

        if added || !done.isEmpty {
            onActivity?(addedEvents, done)
        }
    }
}
