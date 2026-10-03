import Foundation
import Combine

/// What `ScanDemand` switches on and off: a `TranscriptStore` in the app.
public protocol ScanControl: AnyObject {
    func start(announceBacklog: Bool)
    func stop()
}

extension TranscriptStore: ScanControl {}

/// Scans a source only while something needs it: its icon is in the menu bar, or a
/// notification rule is enabled. Rules are not tied to a source, so one enabled rule keeps
/// both scanning; a source that is hidden with no rule to feed costs nothing.
public final class ScanDemand {

    private let menuBar: MenuBarInsertion      // kept alive: its icons are half of the demand
    private var cancellables: Set<AnyCancellable> = []

    public static func isNeeded(iconInserted: Bool, rules: [NotificationRule]) -> Bool {
        iconInserted || rules.contains(where: \.isEnabled)
    }

    public init(settings: SettingsStore, menuBar: MenuBarInsertion, claude: ScanControl, codex: ScanControl) {
        self.menuBar = menuBar
        drive(claude, icon: menuBar.$claude, rules: settings.$rules)
        drive(codex, icon: menuBar.$codex, rules: settings.$rules)
    }

    private func drive<I: Publisher, R: Publisher>(_ store: ScanControl, icon: I, rules: R)
    where I.Output == Bool, I.Failure == Never, R.Output == [NotificationRule], R.Failure == Never {
        // The first value arrives during `sink`, at launch. A source needed from launch
        // announces what it finds, as it always has. One that becomes needed later catches
        // up quietly: no rule was waiting for that history when it happened.
        var atLaunch = true
        icon.combineLatest(rules)
            .map { Self.isNeeded(iconInserted: $0, rules: $1) }
            .removeDuplicates()
            .sink { [weak store] needed in
                if needed {
                    store?.start(announceBacklog: atLaunch)
                } else {
                    store?.stop()
                }
            }
            .store(in: &cancellables)
        atLaunch = false
    }
}
