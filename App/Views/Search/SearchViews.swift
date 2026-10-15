import HermesKit
import SwiftUI

// Search results (`docs/search.md`, `screens/iphone/drawer.elyx` → `drawerSearch`): the drawer on
// iPhone and the sidebar on iPad and Mac show these in place of the history while searching.

/// The filter chips, the count line, matching projects, then one row per chat.
struct SearchResultsSection: View {
    let workspace: BotWorkspace
    var onNavigate: () -> Void = {}

    private var search: ChatSearch { workspace.search }

    var body: some View {
        SearchChips(search: search, workspace: workspace)
            .modifier(SidebarRowInsets())
        if let line = statusLine {
            HStack(spacing: 6) {
                Text(line)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(search.reach == .fullText ? Theme.secondaryText : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if search.isLoading { ProgressView().controlSize(.mini) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .modifier(SidebarRowInsets())
            .accessibilityAddTraits(.updatesFrequently)
        }
        Group {
            ForEach(search.projects) { project in
                SidebarRow(isSelected: workspace.selection == .project(project.id), height: 44) {
                    workspace.selection = .project(project.id)
                    onNavigate()
                } label: {
                    HStack(spacing: 10) {
                        ProjectTile(appearance: ProjectAppearance(color: project.color, icon: project.icon), size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name).font(.subheadline.weight(.semibold))
                            if let path = project.primaryPath {
                                Text(CheckpointsModel.shortened(path))
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .accessibilityLabel(Text("Project \(project.name)"))
            }
            ForEach(search.hits) { hit in
                SearchResultRow(hit: hit, place: search.place(of: hit), isSelected: isSelected(hit)) {
                    workspace.open(hit)
                    onNavigate()
                }
            }
        }
        // The previous results stay, dimmed, while the next ones load.
        .opacity(search.isLoading && !search.shownQuery.isEmpty ? 0.5 : 1)
        .animation(.smooth(duration: 0.2), value: search.isLoading)
    }

    private var statusLine: String? {
        switch search.reach {
        case .savedTitles: String(localized: "Showing saved chats only. Connect to search everything.")
        case .titlesOnly: String(localized: "Searching titles only. Bot Mode searches what was said.")
        case .fullText: search.failure ?? search.countLine
        }
    }

    private func isSelected(_ hit: ChatSearch.Hit) -> Bool {
        if let botName = hit.botName { return workspace.selection == .bot(botName) }
        let ids = [hit.result.sessionID, hit.result.lineageRoot].compactMap { $0 }
        return ids.contains { workspace.selection == .session($0) }
    }
}

/// All / Chats / Projects / Bots / Tasks.
struct SearchChips: View {
    @Bindable var search: ChatSearch
    let workspace: BotWorkspace

    private var filters: [ChatSearch.Filter] {
        ChatSearch.Filter.allCases.filter { filter in
            switch filter {
            case .projects: workspace.projects.isAvailable
            case .bots: workspace.roster != nil
            default: true
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters) { filter in
                    let selected = search.filter == filter
                    Button {
                        search.filter = filter
                    } label: {
                        Text(filter.title)
                            .font(.footnote.weight(selected ? .semibold : .regular))
                            .foregroundStyle(Theme.primaryText)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(selected ? Theme.controlFill : Color.clear, in: Capsule())
                            .overlay { Capsule().strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 1) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
    }
}

/// One chat found (`searchResultRow`): the title and time, the snippet with the matched words
/// bold, then where it lives.
struct SearchResultRow: View {
    let hit: ChatSearch.Hit
    let place: ChatSearch.Place?
    var isSelected = false
    var isCompact = false
    let action: () -> Void

    var body: some View {
        SidebarRow(isSelected: isSelected, height: isCompact ? 64 : 76, action: action) {
            content
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let date = hit.result.date {
                    Text(Formatting.shortRelative(date))
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            SearchSnippet(runs: hit.result.snippetRuns, prefix: author)
                .lineLimit(isCompact ? 1 : 2)
            if let place {
                SearchPlaceLine(place: place)
            }
        }
        .padding(.vertical, 8)
    }

    private var title: String {
        hit.result.title ?? hit.result.preview.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? String(localized: "Untitled chat")
    }

    /// Who wrote the matched message when it wasn't the person.
    private var author: String? {
        guard hit.result.role == "assistant" else { return nil }
        if let place, case .bot(let bot, _) = place { return bot.displayName.isEmpty ? bot.name : bot.displayName }
        return String(localized: "Hermes")
    }

    private var accessibilityText: String {
        var parts = [title]
        if let date = hit.result.date { parts.append(Formatting.relativePhrase(date)) }
        let snippet = SnippetRun.plain(hit.result.snippet)
        parts.append(String(localized: "matched: \(author.map { "\($0): " } ?? "")\(snippet)"))
        if let place { parts.append(SearchPlaceLine.text(for: place)) }
        return parts.joined(separator: ", ")
    }
}

/// The snippet: matched words in primary semibold, the rest secondary; no markers.
struct SearchSnippet: View {
    let runs: [SnippetRun]
    var prefix: String?
    var font: Font = .footnote

    var body: some View {
        Text(attributed)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var text = AttributedString()
        if let prefix {
            var head = AttributedString("\(prefix): ")
            head.foregroundColor = Theme.secondaryText
            text += head
        }
        for run in runs {
            var piece = AttributedString(run.text.replacingOccurrences(of: "\n", with: " "))
            piece.foregroundColor = run.isMatch ? Theme.primaryText : Theme.secondaryText
            if run.isMatch { piece.font = font.weight(.semibold) }
            text += piece
        }
        return text
    }
}

/// Where a chat lives: the project tile and lane, the Bot's face, or the task glyph.
struct SearchPlaceLine: View {
    let place: ChatSearch.Place

    var body: some View {
        HStack(spacing: 6) {
            switch place {
            case .project(let project, _):
                ProjectTile(appearance: ProjectAppearance(color: project.color, icon: project.icon), size: 14)
            case .bot(_, let appearance):
                BotFace(appearance: appearance, size: 16)
            case .task:
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
            }
            Text(Self.text(for: place))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    static func text(for place: ChatSearch.Place) -> String {
        switch place {
        case .project(let project, let lane): [project.name, lane].compactMap { $0 }.joined(separator: " · ")
        case .bot(let bot, _): bot.displayName.isEmpty ? bot.name : bot.displayName
        case .task(let name): String(localized: "Task run · \(name)")
        }
    }
}

/// Nothing found (`drawerNoResults`), with Search All when a chip narrowed it.
struct SearchEmptyState: View {
    let search: ChatSearch

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Text("No chats mention “\(search.shownQuery)”")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            if search.filter != .all {
                Button("Search All") { search.filter = .all }
                    .font(.subheadline.weight(.semibold))
                    .cardButton()
                    .padding(.top, 2)
            } else {
                Text("Try a different word, or a shorter one.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
    }
}
