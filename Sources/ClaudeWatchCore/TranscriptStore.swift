import Foundation
import Combine

/// Owns the live event feed. All file scanning happens on a private serial queue;
/// only the published snapshot crosses to the main thread for SwiftUI.
public final class TranscriptStore: ObservableObject {

    /// Newest-first feed, capped to `maxEvents`. Read on the main thread by the UI.
    @Published public private(set) var events: [CommandEvent] = []
    @Published public private(set) var isLoading = true
    @Published public var isPaused = false {
        didSet { let v = isPaused; queue.async { self.paused = v } }
    }

    private let scanner: EventScanner
    private let queue = DispatchQueue(label: "io.github.adamxbot.claudewatch.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval

    // The following are touched only on `queue`.
    private var offsets: [String: UInt64] = [:]
    private var seen: Set<String> = []
    private var accumulated: [CommandEvent] = []
    private var paused = false
    private let maxEvents = 2000

    public init(scanner: EventScanner = EventScanner(), interval: TimeInterval = 1.0) {
        self.scanner = scanner
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
        let fresh = scanner.parseDelta(offsets: &offsets)
        var added = false
        for event in fresh where !seen.contains(event.id) {
            seen.insert(event.id)
            accumulated.append(event)
            added = true
        }

        guard added || force else {
            if isLoadingNeedsClearing { publishLoadingDone() }
            return
        }

        accumulated.sort { $0.timestamp > $1.timestamp }
        if accumulated.count > maxEvents {
            let dropped = accumulated[maxEvents...]
            for e in dropped { seen.remove(e.id) }
            accumulated.removeLast(accumulated.count - maxEvents)
        }

        let snapshot = accumulated
        DispatchQueue.main.async {
            self.events = snapshot
            self.isLoading = false
        }
    }

    // First successful tick should clear the loading state even when no events match.
    private var loadingCleared = false
    private var isLoadingNeedsClearing: Bool {
        if loadingCleared { return false }
        loadingCleared = true
        return true
    }
    private func publishLoadingDone() {
        DispatchQueue.main.async { self.isLoading = false }
    }
}
