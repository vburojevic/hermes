import HermesKit
import SwiftUI

/// ⌘K: jump to any chat, Bot, place or gateway, or start something new, without leaving the
/// keyboard.
struct QuickOpenView: View {
    let workspace: BotWorkspace

    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var query = ""
    /// The row the arrow keys moved to; the first result when that's gone or there's none.
    @State private var highlighted: Item?
    @FocusState private var searchFocused: Bool

    enum Item: Hashable {
        case newChat, newBot, tasks, skills, pairDevice, settings
        case bot(String)
        case session(String)
        case gateway(UUID)
    }

    private struct Row: Identifiable {
        let item: Item
        let title: String
        var subtitle: String?
        var shortcut: String?
        var id: Item { item }
    }

    private struct ResultGroup: Identifiable {
        let title: LocalizedStringKey
        let rows: [Row]
        /// How well its best row matched (lower is better), to put the best group first.
        var best = 0
        var id: String { rows.first.map { "\($0.item)" } ?? "" }
    }

    #if os(macOS)
    private static let rowHeight: CGFloat = 38
    private static let rowPadding: CGFloat = 4
    #else
    private static let rowHeight: CGFloat = 44
    private static let rowPadding: CGFloat = 7
    #endif

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let groups = groups
        let rows = groups.flatMap(\.rows)
        let active = current(in: rows)
        VStack(spacing: 0) {
            searchField(rows: rows, active: active)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
                    .frame(maxHeight: .infinity)
            } else {
                results(groups, active: active)
            }
            #if os(macOS)
            Divider()
            hints
            #endif
        }
        .background(Theme.canvas)
        .onAppear {
            #if DEBUG
            if let seeded = UserDefaults.standard.string(forKey: "HERMES_OPEN_QUICK"), seeded != "YES" {
                query = seeded
            }
            #endif
            searchFocused = true
        }
        .onChange(of: query) {
            highlighted = nil
        }
    }

    private func current(in rows: [Row]) -> Item? {
        if let highlighted, rows.contains(where: { $0.item == highlighted }) { return highlighted }
        return rows.first?.item
    }

    // MARK: Search

    private func searchField(rows: [Row], active: Item?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            TextField("Search chats, Bots and actions", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .onSubmit { if let active { open(active) } }
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
    }

    private func move(_ step: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.item == current(in: rows) } ?? -1
        let next = min(max(index + step, 0), rows.count - 1)
        highlighted = rows[next].item
    }

    // MARK: Results

    private func results(_ groups: [ResultGroup], active: Item?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, group.id == groups.first?.id ? 4 : 14)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.rows) { row in
                            rowView(row, isHighlighted: row.item == active)
                                .id(row.item)
                        }
                    }
                }
                .padding(8)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: highlighted) { _, item in
                guard let item else { return }
                proxy.scrollTo(item)
            }
        }
    }

    private func rowView(_ row: Row, isHighlighted: Bool) -> some View {
        Button { open(row.item) } label: {
            HStack(spacing: 12) {
                icon(for: row.item)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlightingMatch(in: row.title))
                        .font(.body)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut = row.shortcut {
                    Text(shortcut)
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Self.rowPadding)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.surfaceRaised)
                }
            }
            .contentShape(.rect(cornerRadius: Theme.Radius.row))
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder
    private func icon(for item: Item) -> some View {
        switch item {
        case .bot(let name):
            if let roster = workspace.roster, let bot = roster.bot(named: name) {
                BotFace(appearance: roster.appearance(for: bot), size: 30)
            }
        case .gateway(let id):
            if let bot = app.bots.first(where: { $0.id == id }) {
                BotAvatar(bot: bot, size: 28)
            }
        default:
            Image(systemName: symbol(for: item))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .modifier(IconTile())
        }
    }

    private func symbol(for item: Item) -> String {
        switch item {
        case .newChat: "square.and.pencil"
        case .newBot: "plus"
        case .tasks: "calendar.badge.clock"
        case .skills: "book.closed"
        case .pairDevice: "qrcode"
        case .settings: "gearshape"
        case .session(let key): workspace.session(forKey: key).flatMap { SessionSource($0.source)?.symbol } ?? "bubble.left"
        default: "circle"
        }
    }

    /// The matched part of a title in full strength, the rest a step back.
    private func highlightingMatch(in title: String) -> AttributedString {
        var text = AttributedString(title)
        text.foregroundColor = trimmedQuery.isEmpty ? Theme.primaryText : Theme.secondaryText
        if !trimmedQuery.isEmpty, let range = text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].foregroundColor = Theme.primaryText
            text[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }

    #if os(macOS)
    private var hints: some View {
        HStack(spacing: 16) {
            hint("↑↓", "to move")
            hint("↩", "to open")
            hint("esc", "to close")
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ action: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(Theme.secondaryText)
            Text(action)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }
    #endif

    // MARK: Content

    private var groups: [ResultGroup] {
        let query = trimmedQuery
        var groups: [ResultGroup] = []

        let actions = ranked(actionRows, query) { [$0.title] }
        if let first = actions.first {
            groups.append(ResultGroup(title: "Actions", rows: actions.map { $0.element }, best: first.rank))
        }

        if let roster = workspace.roster {
            let hidden = Set(roster.hiddenBots.map(\.name))
            let bots = ranked(roster.visibleBots + (query.isEmpty ? [] : roster.hiddenBots), query) { [$0.title, $0.handle] }
            let rows = bots
                .prefix(query.isEmpty ? 5 : 20)
                .map { $0.element }
                .map { bot in
                    let detail = bot.role ?? "@\(bot.handle)"
                    return Row(
                        item: .bot(bot.name),
                        title: bot.title,
                        subtitle: hidden.contains(bot.name) ? String(localized: "Hidden · \(detail)") : detail
                    )
                }
            if let first = bots.first {
                groups.append(ResultGroup(title: "Bots", rows: rows, best: first.rank))
            }
        }

        let sessions = ranked(workspace.sessions, query) { [$0.displayTitle, $0.preview ?? ""] }
        let sessionRows = sessions
            .prefix(query.isEmpty ? 6 : 30)
            .map { $0.element }
            .map { session in
                Row(
                    item: .session(session.stableID),
                    title: session.displayTitle,
                    subtitle: [SessionSource(session.source)?.label, Formatting.relativePhrase(session.activityDate)]
                        .compactMap(\.self).joined(separator: " · ")
                )
            }
        if let first = sessions.first {
            groups.append(ResultGroup(title: query.isEmpty ? "Recent Chats" : "Chats", rows: sessionRows, best: first.rank))
        }

        if app.bots.count > 1 {
            let gateways = ranked(app.bots.filter { $0.id != workspace.id }, query) { [$0.name] }
            if let first = gateways.first {
                let rows = gateways.map { Row(item: .gateway($0.element.id), title: $0.element.name, subtitle: $0.element.displayAddress) }
                groups.append(ResultGroup(title: "Switch Gateway", rows: rows, best: first.rank))
            }
        }
        // Stable: equally good groups keep their usual order.
        return groups.enumerated()
            .sorted { ($0.element.best, $0.offset) < ($1.element.best, $1.offset) }
            .map { $0.element }
    }

    private var actionRows: [Row] {
        var rows = [Row(item: .newChat, title: String(localized: "New Chat"), shortcut: "⌘N")]
        if let roster = workspace.roster, roster.isConnected {
            rows.append(Row(item: .newBot, title: String(localized: "New Bot"), shortcut: "⇧⌘N"))
        }
        rows += [
            Row(item: .tasks, title: String(localized: "Tasks"), shortcut: "⇧⌘1"),
            Row(item: .skills, title: String(localized: "Skills"), shortcut: "⇧⌘2"),
            Row(item: .pairDevice, title: String(localized: "Pair a Device")),
            Row(item: .settings, title: String(localized: "Settings"), shortcut: "⌘,"),
        ]
        return rows
    }

    /// The elements that match, best first: a title that starts with the query, then a word
    /// that does, then anywhere. Ties keep their order (recency, roster order).
    private func ranked<Element>(
        _ elements: [Element], _ query: String, fields: (Element) -> [String]
    ) -> [(rank: Int, element: Element)] {
        guard !query.isEmpty else { return elements.map { (0, $0) } }
        return elements.enumerated()
            .compactMap { index, element in
                fields(element).compactMap { rank($0, query) }.min().map { (rank: $0, index: index, element: element) }
            }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map { ($0.rank, $0.element) }
    }

    private func rank(_ text: String, _ query: String) -> Int? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: query, options: options) else { return nil }
        if range.lowerBound == text.startIndex { return 0 }
        let startsAWord = text.split(whereSeparator: \.isWhitespace).contains {
            $0.range(of: query, options: options.union(.anchored)) != nil
        }
        return startsAWord ? 1 : 2
    }

    // MARK: Actions

    private func open(_ item: Item) {
        switch item {
        case .newChat:
            if workspace.sidebarMode != .chats { workspace.sidebarMode = .chats }
            workspace.startNewChat()
            dismiss()
        case .newBot:
            // The New Bot sheet belongs to the window; it can only come up once this one is gone.
            let workspace = workspace
            router?.afterDismiss = {
                workspace.sidebarMode = .bots
                workspace.roster?.isCreatingBot = true
            }
            dismiss()
        case .tasks:
            workspace.selection = .tasks
            dismiss()
        case .skills:
            workspace.selection = .skills
            dismiss()
        case .pairDevice:
            router?.sheet = .pairing(workspace.id)
        case .settings:
            #if os(macOS)
            dismiss()
            openSettings()
            #else
            router?.sheet = .settings
            #endif
        case .bot(let name):
            workspace.sidebarMode = .bots
            workspace.selection = .bot(name)
            dismiss()
        case .session(let key):
            if workspace.sidebarMode != .chats { workspace.sidebarMode = .chats }
            workspace.selection = .session(key)
            dismiss()
        case .gateway(let id):
            dismiss()
            app.select(id)
        }
    }
}

/// A small rounded tile behind an action's symbol.
private struct IconTile: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: 30, height: 30)
            .background(Theme.surface, in: .rect(cornerRadius: 8, style: .continuous))
    }
}
