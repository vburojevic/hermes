#if os(macOS)
import HermesKit
import SwiftUI

/// ⌘K on the Mac (`screens/mac/search.elyx` → `macSearch`): a glass palette over the window with
/// Chats (snippet rows, at most 3, then Show All Results), Projects and Actions. Keyboard only
/// works: ↑↓ move, Return opens, ⌘Return opens in a new window, ⌘1–⌘3 open a project, Esc closes.
struct SearchPalette: View {
    let workspace: BotWorkspace
    let router: WindowRouter

    @State private var search: ChatSearch
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.openWindow) private var openWindow

    init(workspace: BotWorkspace, router: WindowRouter) {
        self.workspace = workspace
        self.router = router
        _search = State(initialValue: ChatSearch(workspace: workspace))
    }

    enum Item: Hashable {
        case chat(ChatSearch.Hit)
        case recent(HermesSession)
        case showAll
        case project(HermesProject)
        case newChat(projectID: String?, name: String?)
        case find(String)
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let items: [Item]
    }

    private var sections: [Section] {
        var sections: [Section] = []
        let typed = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            let recent = workspace.sessions.prefix(3).map(Item.recent)
            if !recent.isEmpty { sections.append(Section(id: "recent", title: String(localized: "Recent Chats"), items: recent)) }
        } else if !search.hits.isEmpty {
            var items = search.hits.prefix(3).map(Item.chat)
            if search.hits.count > 3 { items.append(.showAll) }
            sections.append(Section(id: "chats", title: String(localized: "Chats · \(search.hits.count)"), items: items))
        }
        let projects = typed.isEmpty ? [] : search.projects
        if !projects.isEmpty {
            sections.append(Section(id: "projects", title: String(localized: "Projects"), items: projects.prefix(3).map(Item.project)))
        }
        var actions: [Item] = []
        let active = workspace.projects.activeProjectID.flatMap { workspace.projects.projects[$0] }
        actions.append(.newChat(projectID: active?.id, name: active?.name))
        if !typed.isEmpty, case .session? = workspace.selection {
            actions.append(.find(typed))
        }
        sections.append(Section(id: "actions", title: String(localized: "Actions"), items: actions))
        return sections
    }

    private var items: [Item] { sections.flatMap(\.items) }

    var body: some View {
        let sections = sections
        let items = sections.flatMap(\.items)
        VStack(spacing: 0) {
            field(items: items)
            Divider().overlay(Theme.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.items, id: \.self) { item in
                                let index = items.firstIndex(of: item) ?? 0
                                row(item, index: index)
                                    .id(item)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 440)
                .opacity(search.isLoading && !search.shownQuery.isEmpty ? 0.6 : 1)
                .onChange(of: selected) { _, index in
                    if items.indices.contains(index) { proxy.scrollTo(items[index]) }
                }
            }
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.shadow, radius: 30, y: 12)
        .onAppear {
            fieldFocused = true
            #if DEBUG
            if let text = UserDefaults.standard.string(forKey: "HERMES_PALETTE"), !text.isEmpty { search.query = text }
            #endif
        }
        .onChange(of: search.hits) { selected = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Field

    private func field(items: [Item]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField("Search chats, projects and actions", text: $search.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard items.indices.contains(selected) else { return .handled }
                    open(items[selected], newWindow: press.modifiers.contains(.command))
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "123"), phases: .down) { press in
                    guard press.modifiers.contains(.command), let digit = Int(press.characters) else { return .ignored }
                    let projects = items.compactMap { item -> Item? in if case .project = item { item } else { nil } }
                    guard projects.indices.contains(digit - 1) else { return .ignored }
                    open(projects[digit - 1], newWindow: false)
                    return .handled
                }
            if search.isLoading { Spinner() }
            Text("esc")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        selected = min(max(selected + step, 0), count - 1)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: Item, index: Int) -> some View {
        Button {
            open(item, newWindow: false)
        } label: {
            label(for: item)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index == selected ? Theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selected = index } }
        .accessibilityAddTraits(index == selected ? .isSelected : [])
    }

    @ViewBuilder
    private func label(for item: Item) -> some View {
        switch item {
        case .chat(let hit):
            SearchResultRow(hit: hit, time: search.time(of: hit), place: search.place(of: hit), isCompact: true) {}
                .allowsHitTesting(false)
        case .recent(let session):
            actionLabel(symbol: "bubble.left", title: session.displayTitle, shortcut: nil)
        case .showAll:
            actionLabel(symbol: "list.bullet", title: String(localized: "Show All Results"), shortcut: nil)
        case .project(let project):
            let path = project.primaryPath.map(CheckpointsModel.shortened) ?? ""
            let number = (search.projects.firstIndex(of: project) ?? 0) + 1
            actionLabel(symbol: "folder", title: path.isEmpty ? project.name : "\(project.name) · \(path)", shortcut: number <= 3 ? "⌘\(number)" : nil)
        case .newChat(_, let name):
            actionLabel(symbol: "square.and.pencil", title: name.map { String(localized: "New Chat in \($0)") } ?? String(localized: "New Chat"), shortcut: "⌘N")
        case .find(let text):
            actionLabel(symbol: "text.magnifyingglass", title: String(localized: "Find “\(text)” in This Chat"), shortcut: "⌘F")
        }
    }

    private func actionLabel(symbol: String, title: String, shortcut: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 28)
    }

    // MARK: Acting

    private func open(_ item: Item, newWindow: Bool) {
        let query = search.query
        close()
        switch item {
        case .chat(let hit):
            workspace.open(hit)
        case .recent(let session):
            workspace.sidebarMode = .chats
            workspace.pick(.session(session.stableID))
        case .showAll:
            // The sidebar's search, filtered in place.
            workspace.sidebarMode = .chats
            workspace.searchText = query
            router.focusSidebarSearch()
        case .project(let project):
            workspace.sidebarMode = .chats
            workspace.pick(.project(project.id))
        case .newChat(let projectID, _):
            workspace.sidebarMode = .chats
            workspace.startNewChat(inProject: projectID)
        case .find(let text):
            workspace.currentConversation.find(text)
        }
        // Every window shows the gateway's selection; ⌘Return gives it a window of its own.
        if newWindow { openWindow(id: HermesApp.mainWindow) }
    }

    private func close() {
        router.showsSearchPalette = false
    }
}
#endif
