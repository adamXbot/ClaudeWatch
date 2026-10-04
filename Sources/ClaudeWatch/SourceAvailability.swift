import Foundation
import Combine
import ClaudeWatchCore

/// Polls for local transcripts so `.automatic` icons can follow them. Listing a large
/// ~/.claude or ~/.codex takes seconds, so it happens on a private queue; only changes
/// are published, on the main thread.
final class SourceAvailability: ObservableObject {
    @Published private(set) var hasClaude = false
    @Published private(set) var hasCodex = false

    private let queue = DispatchQueue(label: "io.github.adamxbot.claudewatch.availability", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Begin polling. Safe to call once at app launch.
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 10)
        t.setEventHandler { [weak self] in self?.scan() }
        timer = t
        t.resume()
    }

    func refresh() {
        queue.async { self.scan() }
    }

    // Runs on `queue`.
    private func scan() {
        let hasClaude = EventScanner(source: .claude).discoverFiles().isEmpty == false
        let hasCodex = EventScanner(source: .codex).discoverFiles().isEmpty == false
        DispatchQueue.main.async {
            if self.hasClaude != hasClaude { self.hasClaude = hasClaude }
            if self.hasCodex != hasCodex { self.hasCodex = hasCodex }
        }
    }
}
