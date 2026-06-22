import SwiftUI
import ClaudeWatchCore

struct SettingsView: View {
    let engine: NotificationEngine

    var body: some View {
        TabView {
            RulesTab().tabItem { Label("Rules", systemImage: "bell.badge") }
            WebhooksTab(engine: engine).tabItem { Label("Webhooks", systemImage: "link") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 580, height: 540)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var updater: UpdaterViewModel

    var body: some View {
        Form {
            Toggle("Enable system notifications", isOn: $settings.systemNotificationsEnabled)
            Text("macOS asks for permission the first time. Change it later in System Settings → Notifications → ClaudeWatch.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Add starter rules") {
                for preset in NotificationRule.presets where !settings.rules.contains(where: { $0.name == preset.name }) {
                    settings.rules.append(preset)
                }
            }
            Text("Adds: Git commit, Any file write, Session done.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                Text("v\(UpdaterViewModel.appVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
            Text("Updates are delivered via Sparkle once a signed release is published.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            aboutSection
        }
        .padding(20)
    }

    private var aboutSection: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 22)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ClaudeWatch")
                    .font(.system(size: 13, weight: .semibold))
                Text("Version \(UpdaterViewModel.appVersion) (\(UpdaterViewModel.buildNumber))")
                    .font(.caption).foregroundStyle(.secondary)
                if let repo = URL(string: "https://github.com/adamXbot/ClaudeWatch") {
                    Link("github.com/adamXbot/ClaudeWatch", destination: repo)
                        .font(.caption)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Rules

private struct RulesTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: TranscriptStore

    private var projects: [String] {
        Array(Set(store.events.map(\.projectName))).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Notification rules").font(.headline)
                    Spacer()
                    Menu("Add rule") {
                        Button("Blank rule") { settings.rules.append(NotificationRule(name: "New rule")) }
                        Divider()
                        ForEach(NotificationRule.presets, id: \.name) { preset in
                            Button(preset.name) { settings.rules.append(preset) }
                        }
                    }
                    .fixedSize()
                }
                if settings.rules.isEmpty {
                    Text("No rules yet. Add one to get notified when Claude does something.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                }
                ForEach($settings.rules) { $rule in
                    RuleEditorView(
                        rule: $rule,
                        availableProjects: projects,
                        webhooks: settings.webhooks,
                        onDelete: { settings.rules.removeAll { $0.id == rule.id } }
                    )
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        }
    }
}

private struct RuleEditorView: View {
    @Binding var rule: NotificationRule
    let availableProjects: [String]
    let webhooks: [WebhookDestination]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $rule.isEnabled).labelsHidden()
                TextField("Rule name", text: $rule.name).textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }

            Picker("When", selection: $rule.trigger) {
                ForEach(NotificationTrigger.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if rule.trigger == .action {
                HStack {
                    Picker("Type", selection: $rule.kind) {
                        Text("Any").tag(EventKind?.none)
                        ForEach(EventKind.allCases, id: \.self) { Text($0.label).tag(EventKind?.some($0)) }
                    }
                    .frame(width: 180)
                    TextField("text contains…", text: $rule.textMatch).textFieldStyle(.roundedBorder)
                    Toggle("regex", isOn: $rule.useRegex)
                }
            }

            // Scope
            Toggle("All projects", isOn: $rule.scope.allProjects)
            if !rule.scope.allProjects {
                FlowProjects(projects: availableProjects, selected: $rule.scope.projects)
            }

            // Destinations
            Text("Notify").font(.caption).foregroundStyle(.secondary)
            Toggle("System notification", isOn: destinationBinding(.system))
            ForEach(webhooks) { webhook in
                Toggle("Webhook · \(webhook.name)", isOn: destinationBinding(.webhook(webhook.id)))
            }
        }
    }

    private func destinationBinding(_ destination: RuleDestination) -> Binding<Bool> {
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

private struct FlowProjects: View {
    let projects: [String]
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if projects.isEmpty {
                Text("No projects seen yet.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(projects, id: \.self) { project in
                Toggle(project, isOn: Binding(
                    get: { selected.contains(project) },
                    set: { on in if on { selected.insert(project) } else { selected.remove(project) } }
                ))
                .font(.caption)
            }
        }
        .padding(.leading, 16)
    }
}

// MARK: - Webhooks

private struct WebhooksTab: View {
    let engine: NotificationEngine
    @EnvironmentObject var settings: SettingsStore

    @State private var newName = ""
    @State private var newProvider: WebhookProvider = .discord
    @State private var newURL = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Webhooks").font(.headline)

                ForEach(settings.webhooks) { webhook in
                    WebhookRowView(webhook: webhook, engine: engine)
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider().padding(.vertical, 4)
                Text("Add webhook").font(.subheadline).bold()
                HStack {
                    TextField("Name", text: $newName).frame(width: 130)
                    Picker("", selection: $newProvider) {
                        ForEach(WebhookProvider.allCases) { Text($0.label).tag($0) }
                    }.frame(width: 150).labelsHidden()
                }
                HStack {
                    TextField("https://…  (incoming webhook URL)", text: $newURL).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newURL.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        let name = newName.isEmpty ? newProvider.label : newName
                        settings.addWebhook(WebhookDestination(name: name, provider: newProvider), url: trimmed)
                        newName = ""; newURL = ""
                    }
                }
                Text("URLs are stored in your macOS Keychain, not in plain settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

private struct WebhookRowView: View {
    @EnvironmentObject var settings: SettingsStore
    let webhook: WebhookDestination
    let engine: NotificationEngine
    @State private var urlText = ""
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(webhook.name).bold()
                Text(webhook.provider.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { settings.removeWebhook(webhook.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless)
            }
            HStack {
                TextField("https://…", text: $urlText).textFieldStyle(.roundedBorder)
                Button("Save") { settings.setWebhookURL(urlText, for: webhook.id); status = "Saved" }
                Button("Test") {
                    status = "Testing…"
                    engine.test(provider: webhook.provider, url: urlText) { ok, message in
                        DispatchQueue.main.async { status = (ok ? "✅ " : "⚠️ ") + message }
                    }
                }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { urlText = settings.webhookURL(for: webhook.id) ?? "" }
    }
}
