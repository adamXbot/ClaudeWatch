import Foundation
import Combine

/// Which status items are in the menu bar: the source of truth behind each
/// `MenuBarExtra(isInserted:)` binding.
///
/// SwiftUI reports an extra's insertion state back through that binding on every scene
/// update, not only when the user drags the icon out of the menu bar. Bound straight to
/// `SettingsStore`, each report re-published the store, which invalidated the App, which
/// updated the scenes and produced the next report: a render loop that pinned a core and
/// never showed the popover (macOS 27). So the App observes this object instead of the
/// settings. It publishes only when an icon really appears or disappears, drops reports
/// that match what it already shows, and applies a real removal after the current update.
public final class MenuBarInsertion: ObservableObject {

    @Published public private(set) var claude = false
    @Published public private(set) var codex = false

    /// The fallback icon keeps Settings reachable when neither source is shown.
    public var fallback: Bool { !claude && !codex }

    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    /// `hasClaude` / `hasCodex` say whether local transcripts exist, for `.automatic`.
    public init<A: Publisher, B: Publisher>(settings: SettingsStore, hasClaude: A, hasCodex: B)
    where A.Output == Bool, A.Failure == Never, B.Output == Bool, B.Failure == Never {
        self.settings = settings
        settings.$claudeVisibility.combineLatest(hasClaude)
            .map { $0.isInserted(hasTranscripts: $1) }
            .removeDuplicates()
            .sink { [weak self] in self?.claude = $0 }
            .store(in: &cancellables)
        settings.$codexVisibility.combineLatest(hasCodex)
            .map { $0.isInserted(hasTranscripts: $1) }
            .removeDuplicates()
            .sink { [weak self] in self?.codex = $0 }
            .store(in: &cancellables)
    }

    public func isInserted(_ source: TranscriptSource) -> Bool {
        switch source {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// SwiftUI's report of an extra's state. Only a removal we didn't make ourselves is
    /// news (the user dragged the icon out of the menu bar): it becomes "Hide", on the
    /// next main-queue turn so nothing is published from inside a scene update.
    public func report(_ source: TranscriptSource, inserted: Bool) {
        guard !inserted, isInserted(source) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInserted(source) else { return }
            switch source {
            case .claude: self.settings.claudeVisibility = .hide
            case .codex: self.settings.codexVisibility = .hide
            }
        }
    }
}
