import SwiftUI
import ClaudeWatchCore

struct MenuContentView: View {
    @EnvironmentObject var store: TranscriptStore
    var openSettings: () -> Void = {}
    @State private var searchText = ""
    @State private var hiddenKinds: Set<EventKind> = []
    @State private var hiddenProjects: Set<String> = []
    @State private var showSubagents = true

    private var availableProjects: [String] {
        Array(Set(store.events.map(\.projectName))).sorted()
    }

    private var filtered: [CommandEvent] {
        store.events.filter { event in
            if !showSubagents && event.isSubagent { return false }
            if hiddenKinds.contains(event.kind) { return false }
            if hiddenProjects.contains(event.projectName) { return false }
            if !searchText.isEmpty {
                let q = searchText
                let hit = event.primary.localizedCaseInsensitiveContains(q)
                    || event.projectName.localizedCaseInsensitiveContains(q)
                    || (event.secondary?.localizedCaseInsensitiveContains(q) ?? false)
                if !hit { return false }
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.sessions.isEmpty {
                Divider()
                ActiveSessionsView(sessions: store.sessions)
            }
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Claude activity")
                    .font(.system(size: 13, weight: .semibold))
                if store.isPaused {
                    Text("paused").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                filterMenu
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter commands, projects…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Show subagent activity", isOn: $showSubagents)
            Divider()
            ForEach(EventKind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(
                    get: { !hiddenKinds.contains(kind) },
                    set: { on in
                        if on { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
                    }
                )) {
                    Label(kind.label, systemImage: kind.symbol)
                }
            }
            if !availableProjects.isEmpty {
                Divider()
                Menu("Projects") {
                    Button("Show all") { hiddenProjects.removeAll() }
                    Divider()
                    ForEach(availableProjects, id: \.self) { project in
                        Toggle(isOn: Binding(
                            get: { !hiddenProjects.contains(project) },
                            set: { on in
                                if on { hiddenProjects.remove(project) } else { hiddenProjects.insert(project) }
                            }
                        )) {
                            Text(project)
                        }
                    }
                }
            }
            Divider()
            Toggle("Pause watching", isOn: $store.isPaused)
            Button("Refresh now") { store.refresh() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            centeredMessage("Reading transcripts…", system: "hourglass")
        } else if filtered.isEmpty {
            centeredMessage(
                store.events.isEmpty ? "No activity yet" : "Nothing matches your filter",
                system: "tray"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { event in
                        CommandRowView(event: event, query: searchText)
                        Divider().padding(.leading, 42)
                    }
                }
            }
        }
    }

    private func centeredMessage(_ text: String, system: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: system).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isPaused ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text("\(filtered.count) action\(filtered.count == 1 ? "" : "s") · watching ~/.claude")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.isPaused.toggle() } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(store.isPaused ? "Resume" : "Pause")
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings — notifications & webhooks")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
