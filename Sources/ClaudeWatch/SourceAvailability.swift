import Foundation
import Combine
import ClaudeWatchCore

final class SourceAvailability: ObservableObject {
    @Published private(set) var hasClaude = false
    @Published private(set) var hasCodex = false

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let hasClaude = EventScanner(source: .claude).discoverFiles().isEmpty == false
        let hasCodex = EventScanner(source: .codex).discoverFiles().isEmpty == false
        DispatchQueue.main.async {
            self.hasClaude = hasClaude
            self.hasCodex = hasCodex
        }
    }

    func hasTranscripts(for source: TranscriptSource) -> Bool {
        switch source {
        case .claude: return hasClaude
        case .codex: return hasCodex
        }
    }
}
