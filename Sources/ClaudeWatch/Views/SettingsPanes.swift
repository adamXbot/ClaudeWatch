import SwiftUI
import ClaudeWatchCore

// The panes of the Settings window. Each is a run of grouped-form sections that
// `SurfaceSettings` wraps in a form; General also receives the About button from it.

// MARK: - General

struct GeneralPane: View {
    let app: SurfaceApp
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Section("Startup") {
            SurfaceLaunchAtLoginRow(app: app)
        }
        Section("Menu bar") {
            visibility(
                "Claude", selection: $settings.claudeVisibility,
                info: "Automatic shows the Claude icon only while there are transcripts under ~/.claude. Show keeps it on; Hide turns it off. While neither source shows an icon, a fallback icon keeps Settings reachable."
            )
            visibility(
                "Codex", selection: $settings.codexVisibility,
                info: "Automatic shows the Codex icon only while there are sessions under ~/.codex. Show keeps it on; Hide turns it off. Dragging an icon out of the menu bar sets it to Hide."
            )
        }
        Section("Notifications") {
            Toggle(isOn: $settings.systemNotificationsEnabled) {
                SurfaceInfoLabel(
                    "Enable system notifications",
                    info: "Rules that notify through macOS post a notification here. macOS asks for permission the first time; change it later in System Settings ▸ Notifications ▸ ClaudeWatch."
                )
            }
        }
    }

    private func visibility(_ title: String, selection: Binding<SourceVisibility>, info: String) -> some View {
        Picker(selection: selection) {
            ForEach(SourceVisibility.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        } label: {
            SurfaceInfoLabel(title, info: info)
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Rules

struct RulesPane: View {
    @ObservedObject var settings: SettingsStore
    // Observed for the project list, which grows as the feeds are read.
    @ObservedObject var claudeStore: TranscriptStore
    @ObservedObject var codexStore: TranscriptStore

    private var projects: [String] {
        Array(Set((claudeStore.events + codexStore.events).map(\.projectName))).sorted()
    }

    var body: some View {
        Section {
            LabeledContent {
                Menu("Add Rule") {
                    Button("Blank Rule") { settings.rules.append(NotificationRule(name: "New rule")) }
                    Divider()
                    ForEach(NotificationRule.presets, id: \.name) { preset in
                        Button(preset.name) { settings.rules.append(preset) }
                    }
                    Divider()
                    Button("All Starter Rules") {
                        for preset in NotificationRule.presets
                        where !settings.rules.contains(where: { $0.name == preset.name }) {
                            settings.rules.append(preset)
                        }
                    }
                }
                .fixedSize()
            } label: {
                SurfaceInfoLabel(
                    "Notification rules",
                    info: "A rule fires on a matching action, or when a session finishes, and sends a system notification or a webhook. Rules are not tied to a source: one enabled rule keeps both Claude and Codex transcripts watched, even while their icons are hidden. The starter rules are Git commit, Any file write and Session done."
                )
            }
            .onAppear {
                // The project list comes from the feeds, which a source nobody needed yet
                // has not read.
                claudeStore.loadIfNeeded()
                codexStore.loadIfNeeded()
            }
            if settings.rules.isEmpty {
                Text("No rules yet. Add one to be told when Claude or Codex does something.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach($settings.rules) { $rule in
            Section(rule.name.isEmpty ? "Untitled rule" : rule.name) {
                RuleRows(rule: $rule, projects: projects, webhooks: settings.webhooks) {
                    settings.rules.removeAll { $0.id == rule.id }
                }
            }
        }
    }
}

private struct RuleRows: View {
    @Binding var rule: NotificationRule
    let projects: [String]
    let webhooks: [WebhookDestination]
    let onDelete: () -> Void

    var body: some View {
        TextField("Name", text: $rule.name)
        Toggle("Enabled", isOn: $rule.isEnabled)
        Picker("When", selection: $rule.trigger) {
            ForEach(NotificationTrigger.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)

        if rule.trigger == .action {
            Picker("Action type", selection: $rule.kind) {
                Text("Any").tag(EventKind?.none)
                ForEach(EventKind.allCases, id: \.self) { Text($0.label).tag(EventKind?.some($0)) }
            }
            TextField(text: $rule.textMatch, prompt: Text("Any text")) {
                SurfaceInfoLabel(
                    "Text contains",
                    info: "Matched, ignoring case, against the command or path and its description. Leave it empty to match every action of the chosen type."
                )
            }
            Toggle("Match as a regular expression", isOn: $rule.useRegex)
        }

        Toggle("All projects", isOn: $rule.scope.allProjects)
        if !rule.scope.allProjects {
            if projects.isEmpty {
                Text("No projects seen yet.").foregroundStyle(.secondary)
            }
            ForEach(projects, id: \.self) { project in
                Toggle(project, isOn: Binding(
                    get: { rule.scope.projects.contains(project) },
                    set: { on in
                        if on { rule.scope.projects.insert(project) } else { rule.scope.projects.remove(project) }
                    }
                ))
                .padding(.leading, 16)
            }
        }

        Toggle("Send a system notification", isOn: destination(.system))
        ForEach(webhooks) { webhook in
            Toggle("Send to \(webhook.name)", isOn: destination(.webhook(webhook.id)))
        }

        SurfaceDestructiveButton(
            "Delete Rule…", gate: .confirm,
            question: "Delete the rule “\(rule.name.isEmpty ? "Untitled rule" : rule.name)”?",
            consequence: "It stops notifying and cannot be recovered.",
            confirmTitle: "Delete Rule",
            action: onDelete
        )
    }

    private func destination(_ destination: RuleDestination) -> Binding<Bool> {
        Binding(
            get: { rule.destinations.contains(destination) },
            set: { on in
                if on {
                    if !rule.destinations.contains(destination) { rule.destinations.append(destination) }
                } else {
                    rule.destinations.removeAll { $0 == destination }
                }
            }
        )
    }
}

// MARK: - Webhooks

struct WebhooksPane: View {
    @ObservedObject var settings: SettingsStore
    let engine: NotificationEngine

    @State private var newName = ""
    @State private var newProvider: WebhookProvider = .discord
    @State private var newURL = ""

    private var trimmedURL: String { newURL.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ForEach(settings.webhooks) { webhook in
            Section(webhook.name) {
                WebhookRows(settings: settings, webhook: webhook, engine: engine)
            }
        }
        Section("Add webhook") {
            TextField("Name", text: $newName, prompt: Text(newProvider.label))
            Picker("Provider", selection: $newProvider) {
                ForEach(WebhookProvider.allCases) { Text($0.label).tag($0) }
            }
            TextField(text: $newURL, prompt: Text("https://…")) {
                SurfaceInfoLabel(
                    "URL",
                    info: "The incoming webhook URL from Discord, Slack or Microsoft Teams, or any endpoint that accepts a JSON body. It is kept in your macOS Keychain, not in preferences, because it usually carries a token."
                )
            }
            Button("Add Webhook") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                settings.addWebhook(
                    WebhookDestination(name: name.isEmpty ? newProvider.label : name, provider: newProvider),
                    url: trimmedURL
                )
                newName = ""
                newURL = ""
            }
            .disabled(trimmedURL.isEmpty)
        }
    }
}

private struct WebhookRows: View {
    @ObservedObject var settings: SettingsStore
    let webhook: WebhookDestination
    let engine: NotificationEngine
    @State private var urlText = ""
    @State private var status = ""

    var body: some View {
        LabeledContent("Provider", value: webhook.provider.label)
        TextField("URL", text: $urlText, prompt: Text("https://…"))
        HStack {
            Button("Save") {
                settings.setWebhookURL(urlText, for: webhook.id)
                status = "Saved"
            }
            Button("Send Test") {
                status = "Sending…"
                engine.test(provider: webhook.provider, url: urlText) { ok, message in
                    DispatchQueue.main.async { status = ok ? "Delivered · \(message)" : "Failed · \(message)" }
                }
            }
            Spacer()
            if !status.isEmpty {
                // Live status of the last Save or Send Test.
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        SurfaceDestructiveButton(
            "Remove Webhook…", gate: .confirm,
            question: "Remove the webhook “\(webhook.name)”?",
            consequence: "Its URL is deleted from your Keychain and every rule stops sending to it.",
            confirmTitle: "Remove Webhook"
        ) {
            settings.removeWebhook(webhook.id)
        }
        .onAppear { urlText = settings.webhookURL(for: webhook.id) ?? "" }
    }
}
