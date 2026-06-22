import Foundation
import Combine

/// User-facing settings: notification rules, webhook destinations, and global toggles.
/// Rules + webhook metadata persist in UserDefaults; webhook URLs live in the Keychain.
/// Main-thread object; the engine reads an immutable `snapshot()` on its own queue.
public final class SettingsStore: ObservableObject {

    @Published public var rules: [NotificationRule] { didSet { persist() } }
    @Published public var webhooks: [WebhookDestination] { didSet { persist() } }
    @Published public var systemNotificationsEnabled: Bool { didSet { persist() } }

    /// Called (post-change) whenever settings change, so the app can push a fresh snapshot
    /// to the notification engine.
    public var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let rulesKey = "claudewatch.rules.v1"
    private let webhooksKey = "claudewatch.webhooks.v1"
    private let systemKey = "claudewatch.systemNotifications.v1"
    private var loaded = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rules = []
        self.webhooks = []
        self.systemNotificationsEnabled = true
        load()
        loaded = true
    }

    // MARK: - Webhook URLs (Keychain)

    public func webhookURL(for id: UUID) -> String? { Keychain.get(id.uuidString) }

    public func setWebhookURL(_ url: String, for id: UUID) {
        Keychain.set(url, for: id.uuidString)
        onChange?()
    }

    public func addWebhook(_ webhook: WebhookDestination, url: String) {
        Keychain.set(url, for: webhook.id.uuidString)
        webhooks.append(webhook)            // triggers persist + onChange via didSet/persist
    }

    public func removeWebhook(_ id: UUID) {
        Keychain.delete(id.uuidString)
        webhooks.removeAll { $0.id == id }
        // Drop references to it from rules.
        for i in rules.indices {
            rules[i].destinations.removeAll { $0 == .webhook(id) }
        }
    }

    // MARK: - Snapshot for the engine

    public func snapshot() -> NotificationConfig {
        var resolved: [UUID: NotificationConfig.ResolvedWebhook] = [:]
        for wh in webhooks {
            guard let url = webhookURL(for: wh.id), !url.isEmpty else { continue }
            resolved[wh.id] = .init(name: wh.name, provider: wh.provider, url: url)
        }
        return NotificationConfig(
            systemEnabled: systemNotificationsEnabled,
            rules: rules,
            webhooks: resolved
        )
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: rulesKey),
           let r = try? decoder.decode([NotificationRule].self, from: data) {
            rules = r
        }
        if let data = defaults.data(forKey: webhooksKey),
           let w = try? decoder.decode([WebhookDestination].self, from: data) {
            webhooks = w
        }
        if defaults.object(forKey: systemKey) != nil {
            systemNotificationsEnabled = defaults.bool(forKey: systemKey)
        }
    }

    private func persist() {
        guard loaded else { return }   // don't write during init's initial assignments
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(rules) { defaults.set(data, forKey: rulesKey) }
        if let data = try? encoder.encode(webhooks) { defaults.set(data, forKey: webhooksKey) }
        defaults.set(systemNotificationsEnabled, forKey: systemKey)
        onChange?()
    }
}
