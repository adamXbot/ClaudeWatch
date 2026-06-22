import Foundation

public enum NotificationTrigger: String, Codable, CaseIterable, Hashable {
    case action        // a system-touching action matched
    case sessionDone   // a session finished (working → waiting)

    public var label: String {
        switch self {
        case .action:      return "Action"
        case .sessionDone: return "Session done"
        }
    }
}

public enum WebhookProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    case discord, slack, teams, generic
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .discord: return "Discord"
        case .slack:   return "Slack"
        case .teams:   return "Microsoft Teams"
        case .generic: return "Generic JSON"
        }
    }
}

/// A webhook target. The URL itself lives in the Keychain (keyed by `id`), never here.
public struct WebhookDestination: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var provider: WebhookProvider

    public init(id: UUID = UUID(), name: String, provider: WebhookProvider) {
        self.id = id
        self.name = name
        self.provider = provider
    }
}

public enum RuleDestination: Codable, Hashable {
    case system
    case webhook(UUID)
}

/// Which projects a rule applies to.
public struct ProjectScope: Codable, Hashable {
    public var allProjects: Bool
    public var projects: Set<String>

    public init(allProjects: Bool = true, projects: Set<String> = []) {
        self.allProjects = allProjects
        self.projects = projects
    }

    public func matches(_ project: String) -> Bool {
        allProjects || projects.contains(project)
    }
}

public struct NotificationRule: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: NotificationTrigger
    public var kind: EventKind?       // for .action; nil = any kind
    public var textMatch: String      // substring or regex; "" = any
    public var useRegex: Bool
    public var scope: ProjectScope
    public var destinations: [RuleDestination]

    public init(
        id: UUID = UUID(), name: String, isEnabled: Bool = true,
        trigger: NotificationTrigger = .action, kind: EventKind? = nil,
        textMatch: String = "", useRegex: Bool = false,
        scope: ProjectScope = ProjectScope(), destinations: [RuleDestination] = [.system]
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.kind = kind
        self.textMatch = textMatch
        self.useRegex = useRegex
        self.scope = scope
        self.destinations = destinations
    }

    /// Does this rule fire for a system-touching action event?
    public func matches(event: CommandEvent) -> Bool {
        guard isEnabled, trigger == .action else { return false }
        if let kind, event.kind != kind { return false }
        if !scope.matches(event.projectName) { return false }

        let needle = textMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let haystack = event.primary + " " + (event.secondary ?? "")
        if useRegex {
            guard let re = try? NSRegularExpression(pattern: needle, options: [.caseInsensitive]) else {
                return false
            }
            return re.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    /// Does this rule fire when a session in `project` finishes?
    public func matchesSessionDone(project: String) -> Bool {
        isEnabled && trigger == .sessionDone && scope.matches(project)
    }

    /// A few sensible starter rules.
    public static var presets: [NotificationRule] {
        [
            NotificationRule(name: "Git commit", trigger: .action, kind: .shell, textMatch: "git commit"),
            NotificationRule(name: "Any file write", trigger: .action, kind: .fileWrite),
            NotificationRule(name: "Session done", trigger: .sessionDone),
        ]
    }
}

/// An immutable, thread-safe snapshot the engine reads on its background queue.
public struct NotificationConfig {
    public struct ResolvedWebhook {
        public var name: String
        public var provider: WebhookProvider
        public var url: String
    }
    public var systemEnabled: Bool
    public var rules: [NotificationRule]
    public var webhooks: [UUID: ResolvedWebhook]

    public init(systemEnabled: Bool, rules: [NotificationRule], webhooks: [UUID: ResolvedWebhook]) {
        self.systemEnabled = systemEnabled
        self.rules = rules
        self.webhooks = webhooks
    }

    public static let empty = NotificationConfig(systemEnabled: true, rules: [], webhooks: [:])
}
