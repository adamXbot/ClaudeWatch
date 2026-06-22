import Foundation
import UserNotifications

/// Posts native macOS notifications. No-ops when not running inside an app bundle
/// (e.g. `swift run … --dump`), where UNUserNotificationCenter is unavailable.
public enum SystemNotifier {
    public static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Evaluates events + session-done signals against the configured rules and dispatches to
/// system notifications and webhooks. `process` runs on the store's serial scan queue;
/// `updateConfig` may be called from the main thread.
public final class NotificationEngine {

    private let lock = NSLock()
    private var config = NotificationConfig.empty
    private var lastFired: [UUID: Date] = [:]   // per-rule cooldown; touched only on the scan queue
    private let cooldown: TimeInterval = 3
    private let urlSession: URLSession

    public init(urlSession: URLSession = URLSession(configuration: .ephemeral)) {
        self.urlSession = urlSession
    }

    public func updateConfig(_ newConfig: NotificationConfig) {
        lock.lock(); config = newConfig; lock.unlock()
    }

    public func process(events: [CommandEvent], doneSessions: [SessionStatus]) {
        lock.lock(); let cfg = config; lock.unlock()
        guard !cfg.rules.isEmpty else { return }

        for event in events {
            for rule in cfg.rules where rule.matches(event: event) {
                dispatch(rule: rule,
                         title: "ClaudeWatch · \(event.projectName)",
                         body: "\(rule.name): \(event.primary)",
                         cfg: cfg)
            }
        }
        for done in doneSessions {
            for rule in cfg.rules where rule.matchesSessionDone(project: done.projectName) {
                dispatch(rule: rule,
                         title: "Claude is done · \(done.projectName)",
                         body: done.statusText,
                         cfg: cfg)
            }
        }
    }

    private func dispatch(rule: NotificationRule, title: String, body: String, cfg: NotificationConfig) {
        let now = Date()
        if let last = lastFired[rule.id], now.timeIntervalSince(last) < cooldown { return }
        lastFired[rule.id] = now

        for destination in rule.destinations {
            switch destination {
            case .system:
                if cfg.systemEnabled { SystemNotifier.post(title: title, body: body) }
            case .webhook(let id):
                if let webhook = cfg.webhooks[id] { send(to: webhook, text: "\(title)\n\(body)") }
            }
        }
    }

    // MARK: - Webhooks

    public func send(to webhook: NotificationConfig.ResolvedWebhook, text: String) {
        guard let url = URL(string: webhook.url) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.payload(provider: webhook.provider, text: text)
        urlSession.dataTask(with: request).resume()
    }

    /// Fire a one-off test message; reports success and a short status string.
    public func test(provider: WebhookProvider, url: String, completion: @escaping (Bool, String) -> Void) {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else {
            completion(false, "Invalid URL"); return
        }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.payload(provider: provider, text: "ClaudeWatch test notification ✅")
        urlSession.dataTask(with: request) { _, response, error in
            if let error { completion(false, error.localizedDescription); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(code), "HTTP \(code)")
        }.resume()
    }

    /// Provider-specific JSON body. Discord uses `content`; Slack/generic use `text`;
    /// Teams uses a legacy MessageCard.
    static func payload(provider: WebhookProvider, text: String) -> Data {
        let object: [String: Any]
        switch provider {
        case .discord:
            object = ["content": text]
        case .slack:
            object = ["text": text]
        case .teams:
            object = ["@type": "MessageCard", "@context": "http://schema.org/extensions",
                      "summary": "ClaudeWatch", "text": text]
        case .generic:
            object = ["text": text]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(text.utf8)
    }
}
