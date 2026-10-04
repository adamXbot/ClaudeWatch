import Foundation
import Combine

/// Owns the live event feed and per-session status. All file scanning and tracking
/// happens on a private serial queue; only published snapshots cross to the main thread.
///
/// The store does work in proportion to what changes, not to how much history there is:
/// - The first read is bounded by what can still matter: the sessions of the last day in
///   full, and older transcripts only as far back as the feed reaches (`load`).
/// - After that a file watcher names the transcripts that were written, and only those are
///   read. Nothing is listed or polled while the history is quiet.
/// - A one-second clock recomputes session state, which depends on the time, and runs only
///   while a session is recent enough to be shown.
public final class TranscriptStore: ObservableObject {

    /// Newest-first event feed, capped to `maxEvents`. Read on the main thread by the UI.
    @Published public private(set) var events: [CommandEvent] = []
    /// Recently-active sessions with their working/waiting state.
    @Published public private(set) var sessions: [SessionStatus] = []
    @Published public private(set) var isLoading = true
    @Published public var isPaused = false {
        didSet { let v = isPaused; queue.async { self.setPaused(v) } }
    }

    /// Called on the scan queue whenever new events arrive or sessions finish. The app
    /// routes this into the notification engine. Either array may be empty. History is not
    /// news: what a start or a refresh reads goes into the feed without coming here.
    public var onActivity: ((_ newEvents: [CommandEvent], _ doneSessions: [SessionStatus]) -> Void)?

    private let scanner: EventScanner
    private let tracker: SessionTracker
    private let watcher: TranscriptWatching?
    private let queue = DispatchQueue(label: "io.github.adamxbot.claudewatch.scan", qos: .utility)
    private let interval: TimeInterval
    private let relistInterval: TimeInterval
    private let maxEvents: Int

    /// A transcript's modification date is trusted to be no older than its last record,
    /// give or take this much.
    private let clockSlack: TimeInterval = 300
    /// The least time between two directory listings: how often a store without a watcher
    /// looks for new files, and what keeps a watcher that keeps losing track from turning
    /// into a listing per second.
    private var listingSpacing: TimeInterval { interval * 5 }

    // Touched only on `queue`.
    private var offsets: [String: UInt64] = [:]
    private var seen: Set<String> = []
    private var accumulated: [CommandEvent] = []
    private var paused = false
    private var loadingCleared = false
    private var active = false                  // started and not stopped
    private var loaded = false                  // the first read has happened
    private var watching = false                // the watcher is reporting changes
    private var changed: Set<String> = []       // reported by the watcher, not read yet
    private var needsListing = false            // only a fresh listing says what changed
    private var lastListing = Date.distantPast
    private var quietCatchUp = false            // the next scan's findings are not announced
    private var readThisLoad: Set<String>?      // ids met during the first read, kept or not
    private var clock: DispatchSourceTimer?     // recomputes time-dependent session state
    private var audit: DispatchSourceTimer?     // re-lists now and then in case the watcher missed something
    /// The clock is off because no session's state can change with time (rather than
    /// because the user paused). The tracker is then brought up to date before new
    /// records are read, as the every-second tick used to keep it.
    private var resting = false

    /// - Parameters:
    ///   - interval: how often session state is recomputed while a session is on show, and
    ///     how often files are checked when there is no watcher.
    ///   - relistInterval: how often the directories are listed again as a safety net
    ///     while a watcher is running.
    ///   - watcher: reports changed files; nil falls back to polling.
    public init(
        scanner: EventScanner = EventScanner(),
        tracker: SessionTracker = SessionTracker(),
        interval: TimeInterval = 1.0,
        relistInterval: TimeInterval = 300,
        maxEvents: Int = 2000,
        watcher: TranscriptWatching? = FSEventsWatcher()
    ) {
        self.scanner = scanner
        self.tracker = tracker
        self.interval = interval
        self.relistInterval = relistInterval
        self.maxEvents = max(1, maxEvents)
        self.watcher = watcher
    }

    deinit {
        clock?.cancel()
        audit?.cancel()
        // Stop on the queue the watcher delivers on, so it cannot be mid-callback.
        if let watcher { queue.async { watcher.stop() } }
    }

    /// Begin watching, or resume after `stop()`. Safe to call repeatedly.
    ///
    /// The first scan after a start catches up on history, and none of that is announced:
    /// launching the app, enabling a rule or showing an icon does not replay old activity
    /// as fresh notifications. `onActivity` hears of what is written from then on.
    public func start() {
        queue.async { self.activate() }
    }

    /// Stop watching. The feed is kept, and `start` picks up from where this left off.
    public func stop() {
        queue.async { self.deactivate() }
    }

    /// Read the history once if that has not happened yet, without starting to watch it.
    public func loadIfNeeded() {
        queue.async {
            if !self.loaded { self.load(now: Date()) }
        }
    }

    /// Force a re-read from scratch (used by the manual refresh button). It rebuilds the
    /// feed and announces none of it again.
    public func refresh() {
        queue.async {
            self.offsets.removeAll()
            self.scanner.reset()
            self.seen.removeAll()
            self.accumulated.removeAll()
            self.load(now: Date())
        }
    }

    /// Runs `body` on the scan queue, after everything already queued there (for tests
    /// and measurements).
    func onScanQueue<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    /// Whether the session clock is ticking. Read it through `onScanQueue`.
    var isClockRunning: Bool { clock != nil }

    // MARK: - Lifecycle (runs on `queue`)

    private func activate() {
        guard !active else { return }
        active = true
        quietCatchUp = true
        // Watch before reading, so nothing written in between is missed.
        watching = watcher?.start(directories: scanner.transcriptDirectories, queue: queue) { [weak self] paths in
            self?.filesChanged(paths)
        } ?? false
        if watching { startAudit() }
        needsListing = true
        if !paused { scan() }
    }

    private func deactivate() {
        guard active else { return }
        active = false
        watcher?.stop()
        watching = false
        audit?.cancel()
        audit = nil
        changed.removeAll()
        setClock(running: false)
    }

    private func setPaused(_ value: Bool) {
        paused = value
        if value {
            setClock(running: false)
        } else if active {
            scan()
        }
    }

    private func filesChanged(_ paths: [String]?) {
        guard active else { return }
        if let paths {
            // The directories hold more than transcripts; other files are not news.
            let transcripts = paths.filter(scanner.isTranscript)
            if transcripts.isEmpty { return }
            changed.formUnion(transcripts)
        } else {
            needsListing = true
        }
        if !paused { scan() }
    }

    private func startAudit() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + relistInterval, repeating: relistInterval, leeway: .seconds(10))
        t.setEventHandler { [weak self] in
            guard let self, self.active, !self.paused else { return }
            self.needsListing = true
            self.scan()
        }
        audit = t
        t.resume()
    }

    /// Keep the clock running only while it has something to do.
    private func setClock(running: Bool) {
        guard running, active, !paused else {
            clock?.cancel()
            clock = nil
            resting = !paused
            return
        }
        resting = false
        guard clock == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        clock = t
        t.resume()
    }

    // MARK: - Scanning (runs on `queue`)

    private func tick() {
        if paused { return }
        scan()
    }

    /// One pass: read what changed, fold it into the feed, recompute sessions, publish.
    private func scan() {
        let now = Date()
        // Stays quiet until the catch-up listing has actually run.
        let announce = !quietCatchUp

        guard loaded else {
            quietCatchUp = false
            load(now: now)
            return
        }

        // Evictions the idle clock did not get to make, before new records arrive.
        if resting { _ = tracker.snapshot(now: now) }

        var fresh: [CommandEvent] = []
        let onRecord: ([String: Any], String) -> Void = { [scanner, tracker] record, path in
            fresh.append(contentsOf: scanner.events(fromRecord: record, transcriptPath: path))
            // The tracker may never have been given this file's first record (see `load`),
            // which says whose session it is. The scanner knows either way.
            tracker.ingest(record: record, path: path, codexContext: scanner.codexContext(for: path))
        }

        if (needsListing || !watching) && now.timeIntervalSince(lastListing) >= listingSpacing {
            // Newly-discovered files are read from the beginning; vanished ones are pruned.
            let files = scanner.listFiles()
            lastListing = now
            needsListing = false
            quietCatchUp = false
            changed.removeAll()
            scanner.read(files, offsets: &offsets, onRecord: onRecord)
            scanner.prune(offsets: &offsets, keeping: files)
        } else {
            // Without a watcher, every known file is checked; with one, only those it named.
            let paths = watching ? changed : Set(offsets.keys)
            changed.removeAll()
            var files: [TranscriptFile] = []
            for path in paths {
                let known = offsets[path] != nil
                if let file = scanner.file(atPath: path, known: known) {
                    files.append(file)
                } else if known {
                    scanner.forget(path, offsets: &offsets)
                }
            }
            scanner.read(files, offsets: &offsets, onRecord: onRecord)
        }

        finish(now: now, added: merge(fresh), announce: announce)
    }

    /// The first read of a history, bounded by what can still matter instead of by how much
    /// there is.
    /// - Sessions written to within the tracker's eviction horizon are read whole, for the
    ///   feed and the tracker. (The tracker would forget any older session at once.)
    /// - Older transcripts are read for their events alone, newest first, and only while
    ///   they could still hold something newer than the oldest event of a full feed.
    /// - The rest are marked as read without being opened.
    /// It still counts as one scan: an event that appears in several transcripts is taken
    /// once, and sessions are only evaluated at the end, when every transcript of a session
    /// has been read.
    ///
    /// What it reads is history, and is not announced. The exception is an event newer than
    /// `now`: it was written while this read was running, and the read got to its file
    /// before the watcher's report could.
    private func load(now: Date) {
        loaded = true
        let files = scanner.listFiles()
        lastListing = now
        needsListing = false
        changed.removeAll()

        let sessionCutoff = now.addingTimeInterval(-(tracker.evictionHorizon + clockSlack))
        readThisLoad = []
        var lastPublish = Date()
        for (file, live) in scanner.backfillOrder(files, liveSince: sessionCutoff) {
            var fresh: [CommandEvent] = []
            if live {
                scanner.read([file], offsets: &offsets) { [scanner, tracker] record, path in
                    fresh.append(contentsOf: scanner.events(fromRecord: record, transcriptPath: path))
                    tracker.ingest(record: record, path: path, codexContext: scanner.codexContext(for: path))
                }
            } else if accumulated.count < maxEvents
                        || file.modified.addingTimeInterval(clockSlack) >= accumulated[maxEvents - 1].timestamp {
                fresh = scanner.readEvents([file], offsets: &offsets)
            } else {
                // The feed's oldest event only gets newer from here on, so a file too old
                // for it now stays too old.
                scanner.skip(file, offsets: &offsets)
                continue
            }
            let new = merge(fresh)
            let news = new.filter { $0.timestamp >= now }
            if !news.isEmpty { onActivity?(news, []) }

            // Show the feed as it fills, newest first.
            if !new.isEmpty, Date().timeIntervalSince(lastPublish) >= 0.25 {
                lastPublish = Date()
                let snapshot = accumulated
                loadingCleared = true
                DispatchQueue.main.async {
                    self.events = snapshot
                    self.isLoading = false
                }
            }
        }
        readThisLoad = nil
        scanner.prune(offsets: &offsets, keeping: files)

        // A session that finished while this ran is news. Only a refresh can find one: on a
        // first read every session is a first sighting.
        finish(now: now, added: [], publishEvents: !accumulated.isEmpty, announce: true)
    }

    /// Adds the events the feed does not have yet, keeps it newest-first and capped, and
    /// returns what was added.
    private func merge(_ fresh: [CommandEvent]) -> [CommandEvent] {
        var added: [CommandEvent] = []
        for event in fresh where !seen.contains(event.id) {
            if readThisLoad?.insert(event.id).inserted == false { continue }
            seen.insert(event.id)
            accumulated.append(event)
            added.append(event)
        }
        if !added.isEmpty {
            accumulated.sort { $0.timestamp > $1.timestamp }
            if accumulated.count > maxEvents {
                for e in accumulated[maxEvents...] { seen.remove(e.id) }
                accumulated.removeLast(accumulated.count - maxEvents)
            }
        }
        return added
    }

    private func finish(now: Date, added: [CommandEvent], publishEvents: Bool? = nil, announce: Bool) {
        // Sessions are time-dependent, so recompute on every pass.
        let sessionSnapshot = tracker.snapshot(now: now)
        let done = tracker.drainDone()

        let eventsChanged = publishEvents ?? !added.isEmpty
        let eventsSnapshot = accumulated
        let clearedLoading = !loadingCleared
        loadingCleared = true

        DispatchQueue.main.async {
            if eventsChanged { self.events = eventsSnapshot }
            if self.sessions != sessionSnapshot { self.sessions = sessionSnapshot }
            if clearedLoading || eventsChanged { self.isLoading = false }
        }

        if announce, !added.isEmpty || !done.isEmpty {
            onActivity?(added, done)
        }

        // Session state only moves with time while a session is recent enough to be shown.
        // Without a watcher the clock is also what notices new records, and it brings a
        // postponed listing round again.
        setClock(running: !watching || needsListing || !sessionSnapshot.isEmpty)
    }
}
