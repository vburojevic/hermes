import HermesKit
import SwiftUI

/// What this Hermes knows how to do (`screens/iphone/skills.elyx`, `screens/ipad/skills.elyx`,
/// `screens/mac/skills.elyx`): Tools and Apps first (managed in Settings), then the skills by
/// category, as rows on iPhone and a grid of cards on iPad and Mac. Use puts a skill in the
/// composer's tray (`docs/bots-groups-skills.md`).
struct SkillsView: View {
    let workspace: BotWorkspace

    /// The window's skill filter, kept with the window.
    @SceneStorage("skills.query") private var query = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(WindowRouter.self) private var router: WindowRouter?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var catalog: SkillCatalog { workspace.skillCatalog }

    private var groupedSkills: [SkillCatalog.Group] {
        catalog.groups(matching: query, generalTitle: String(localized: "General"))
    }

    /// What shows where the skills go: them, placeholders, or why there are none.
    private var shown: SkillCatalog.Shown {
        catalog.shown(for: workspace.bot.baseURL, isLoading: workspace.isLoadingSkills,
                      isUnreachable: workspace.connection.isFailed)
    }

    /// iPad (regular width) and Mac: the grid of cards.
    private var usesGrid: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            if workspace.showsLearned {
                LearnedHost(workspace: workspace, scope: workspace.learnedScope, embedded: true) { workspace.showsLearned = false }
                    .id(workspace.learnedScope)
                    .id(workspace.id)
            } else {
                grid
            }
            #else
            if usesGrid { grid } else { list }
            #endif
        }
        .background(Theme.canvas)
        #if os(iOS)
        .searchable(text: $query, placement: .toolbar, prompt: "Search skills")
        #else
        .modifier(SkillsSearch(query: $query, isShown: !workspace.showsLearned))
        #endif
        .navigationTitle("Skills")
        .toolbar {
            #if os(macOS)
            // Skills → Library | Learned (`macLearned`).
            ToolbarItem(placement: .primaryAction) {
                Picker("Skills", selection: Binding(get: { workspace.showsLearned }, set: { workspace.showsLearned = $0 })) {
                    Text("Library").tag(false)
                    Text("Learned").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .disabled(workspace.roster == nil)
            }
            #endif
        }
        #if os(iOS)
        .navigationDestination(isPresented: Binding(get: { workspace.showsLearned }, set: { workspace.showsLearned = $0 })) {
            LearnedHost(workspace: workspace, scope: workspace.learnedScope) { workspace.showsLearned = false }
                .id(workspace.learnedScope)
        }
        #endif
        // The list is read once per gateway (kept by the workspace), when Skills first opens or
        // the gateway first comes online, and again after a turn writes a skill; opening Skills
        // again shows it at once.
        .task(id: LoadTrigger(workspace: workspace)) { await workspace.loadSkills() }
        // Tools and Apps asks Bot Mode: a Skills page opened before it connected asks once it does,
        // so the row's placeholder doesn't wait forever.
        .task(id: workspace.roster?.isConnected == true) { await loadAppsAndTools() }
        .onChange(of: workspace.pendingSkillQuery, initial: true) { _, pending in
            // Show Skill on a skill chip opens Skills filtered to it.
            guard let pending else { return }
            query = pending
            workspace.pendingSkillQuery = nil
        }
        .refreshable {
            await workspace.loadSkills(force: true)
            await workspace.loadLearnedSkillsSubtitle(force: true)
            await loadAppsAndTools()
        }
        .overlay {
            if !query.isEmpty && groupedSkills.isEmpty && !catalog.skills.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    // MARK: iPhone

    private var list: some View {
        List {
            if query.isEmpty, workspace.roster != nil {
                Section {
                    LearnedSkillsRow(workspace: workspace) { workspace.showsLearned = true }
                }
                #if os(iOS)
                .listSectionSpacing(12)
                #endif
            }
            if query.isEmpty {
                Section {
                    ToolsAndAppsRow(model: workspace.appsAndTools, isWide: false, action: openAppsAndTools)
                } footer: {
                    Text("Skills teach Hermes how to do things; tools and apps are what it can reach. Manage those in Settings → Apps and Tools.")
                }
            }
            if shown != .list {
                Section {
                    listState
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(groupedSkills) { group in
                Section(group.title) {
                    ForEach(group.skills) { skill in
                        SkillRow(skill: skill) { workspace.use(skill) }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        // White cards on the grouped grey (`skills`).
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
    }

    // MARK: iPad and Mac

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                Text("Skills")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.bottom, 6)
                #endif
                if query.isEmpty {
                    #if os(iOS)
                    if workspace.roster != nil {
                        LearnedSkillsRow(workspace: workspace, isWide: true) { workspace.showsLearned = true }
                    }
                    #endif
                    ToolsAndAppsRow(model: workspace.appsAndTools, isWide: true, action: openAppsAndTools)
                        .padding(.bottom, 8)
                }
                if shown != .list {
                    gridState
                }
                ForEach(groupedSkills) { group in
                    Text(group.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(group.skills) { skill in
                            SkillCard(skill: skill) { workspace.use(skill) }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // White cards on the grouped background. The Mac grid draws its own large title.
        .background(Theme.groupedBackground)
        #if os(macOS)
        .toolbar(removing: .title)
        #endif
    }

    /// Adaptive cards 230 to 360 pt wide, three a row on an iPad and the Mac; at the accessibility
    /// sizes at least 420 pt wide, so usually two a row, each as tall as its words (`ipadSkillsAx5`).
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 420), spacing: 14)]
            : [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 14)]
    }

    // MARK: States

    // Placeholders until the first answer, never an empty page; then why there are no skills
    // (`docs/bots-groups-skills.md` §3).

    /// iPhone: a card of placeholder rows, or the notice.
    @ViewBuilder
    private var listState: some View {
        switch shown {
        case .placeholders:
            SkeletonRows()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel("Loading skills")
        case .empty:
            emptyMessage
                .padding(.top, 60)
        case .failed(let failure):
            failedNotice(failure)
        case .offline:
            offlineNotice
        case .list:
            EmptyView()
        }
    }

    /// iPad and Mac: placeholder cards, or the notice.
    @ViewBuilder
    private var gridState: some View {
        switch shown {
        case .placeholders:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    SkillCardPlaceholder()
                }
            }
            .padding(.top, 8)
            .accessibilityElement()
            .accessibilityLabel("Loading skills")
        case .empty:
            emptyMessage
                .padding(.top, 120)
        case .failed(let failure):
            failedNotice(failure)
        case .offline:
            offlineNotice
        case .list:
            EmptyView()
        }
    }

    private var emptyMessage: some View {
        StateMessage(symbol: "book.closed", title: "No skills yet",
                     message: "Install skills with hermes skills on the gateway, or teach Hermes one with /learn in a chat.")
            .frame(maxWidth: .infinity)
    }

    private func failedNotice(_ failure: HermesError) -> some View {
        MemoryNotice(symbol: "exclamationmark.triangle", title: String(localized: "Couldn't list skills"),
                     detail: String(localized: "This Hermes version couldn't list its skills. \(failure.errorDescription ?? "")")) {
            Task { await workspace.loadSkills(force: true) }
        }
    }

    private var offlineNotice: some View {
        MemoryNotice(symbol: "wifi.slash", title: String(localized: "\(workspace.bot.name) is offline"),
                     detail: String(localized: "Skills show when it's back."))
    }

    /// What reads the list again: another workspace, a new address, the gateway coming online, a
    /// turn that wrote a skill.
    private struct LoadTrigger: Equatable {
        let workspace: UUID
        let address: URL
        let isOnline: Bool
        let generation: Int

        init(workspace: BotWorkspace) {
            self.workspace = workspace.id
            address = workspace.bot.baseURL
            isOnline = workspace.connection.isOnline
            generation = workspace.skillsGeneration
        }
    }

    private func loadAppsAndTools() async {
        guard workspace.roster?.isConnected == true, !workspace.appsAndTools.hasLoaded,
              !workspace.appsAndTools.isLoading else { return }
        await workspace.appsAndTools.load()
    }

    /// Settings → Apps and Tools: the Settings sheet (iPhone, iPad) or the Settings window's tab.
    private func openAppsAndTools() {
        #if os(macOS)
        UserDefaults.standard.set("apps", forKey: MacSettingsView.paneKey)
        openSettings()
        #else
        router?.showAppsAndTools()
        #endif
    }
}

#if os(macOS)
/// The skills search, only while Library shows.
private struct SkillsSearch: ViewModifier {
    @Binding var query: String
    let isShown: Bool

    func body(content: Content) -> some View {
        if isShown {
            content.searchable(text: $query, placement: .toolbar, prompt: "Search skills")
        } else {
            content
        }
    }
}
#endif

/// The skill's glyph: by name for the common ones, else by category.
enum SkillGlyph {
    static func symbol(for skill: Skill) -> String {
        symbol(name: skill.name, category: skill.category)
    }

    static func symbol(name rawName: String, category: String? = nil) -> String {
        let name = rawName.lowercased()
        let byName: [(String, String)] = [
            ("github", "arrow.triangle.branch"), ("pr-", "arrow.triangle.branch"), ("test", "checkmark.square"),
            ("xcode", "hammer"), ("build", "hammer"), ("arxiv", "doc.text"), ("paper", "doc.text"),
            ("blog", "envelope"), ("mail", "envelope"), ("research", "globe"), ("web", "globe"),
            ("synology", "externaldrive"), ("nas", "externaldrive"), ("excalidraw", "pencil.line"), ("draw", "pencil.line"),
            ("home-assistant", "lightbulb"), ("homeassistant", "lightbulb"), ("calendar", "calendar"), ("music", "music.note"),
        ]
        if let match = byName.first(where: { name.contains($0.0) }) { return match.1 }
        switch category?.lowercased() ?? "" {
        case let c where c.contains("research"): return "doc.text.magnifyingglass"
        case let c where c.contains("dev") || c.contains("software"): return "chevron.left.forwardslash.chevron.right"
        case let c where c.contains("ops"): return "server.rack"
        case let c where c.contains("creative") || c.contains("design"): return "paintbrush"
        case let c where c.contains("productivity"): return "checklist"
        case let c where c.contains("media"): return "play.rectangle"
        default: return "book.closed"
        }
    }
}

/// "Tools and Apps": what Hermes can reach, managed in Settings → Apps and Tools. Replaces the
/// toolset switches that used to live here.
private struct ToolsAndAppsRow: View {
    let model: AppsAndToolsModel
    let isWide: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.medium))
                    // The tile keeps its size at every text size, so the glyph does too.
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 34, height: 34)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools and Apps")
                        .foregroundStyle(Theme.primaryText)
                    if model.hasLoaded || !model.isOnline {
                        Text(isWide ? model.toolsSummary + " · " + String(localized: "managed in Settings") : model.toolsSummary)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    } else {
                        // Still asking the gateway: a placeholder line, never the word Loading.
                        SkeletonRows(count: 1, twoLines: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(isWide ? 14 : 0)
            .background(isWide ? Theme.groupedCell : Color.clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings, Apps and Tools")
    }
}

/// A skill on iPhone (`skillRow`): glyph, name, description, Use.
private struct SkillRow: View {
    let skill: Skill
    let onUse: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the accessibility sizes the glyph, the words and Use stack (`skillsAx5`).
        let stacks = typeSize.isAccessibilitySize
        let layout = stacks ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            Image(systemName: SkillGlyph.symbol(for: skill))
                .font(.subheadline.weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .foregroundStyle(Theme.primaryText)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                if let description = skill.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(stacks ? nil : 3)
                }
            }
            if !stacks { Spacer(minLength: 8) }
            Button("Use", action: onUse)
                .font(.subheadline.weight(.semibold))
                .cardButton()
                .controlSize(.small)
                .accessibilityLabel("Use \(skill.name)")
        }
        .padding(.vertical, 4)
    }
}

/// A skill on iPad and Mac (`skillCard`): glyph tile and Use, the name, two lines of description.
private struct SkillCard: View {
    let skill: Skill
    let onUse: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: SkillGlyph.symbol(for: skill))
                    .font(.subheadline.weight(.medium))
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Spacer()
                Button("Use", action: onUse)
                    .font(.footnote.weight(.semibold))
                    .cardButton()
                    .controlSize(.small)
                    .accessibilityLabel("Use \(skill.name)")
            }
            Text(skill.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .padding(.top, 4)
            Text(skill.description ?? "")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                // At accessibility sizes the description wraps in full and reserves nothing.
                .lineLimit(typeSize.isAccessibilitySize ? Int.max : 2, reservesSpace: !typeSize.isAccessibilitySize)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .frame(minHeight: 118, alignment: .top)
        #else
        .frame(minHeight: 150, alignment: .top)
        #endif
        .background(hovering ? Theme.controlFill : Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        #if os(macOS)
        // The Mac card: a hover fill, what it does on hover, and its menu (`macSkills`).
        .onHover { hovering = $0 }
        .help(skill.description ?? skill.name)
        .contextMenu {
            Button("Use in a Chat", systemImage: "text.bubble", action: onUse)
            Button("Copy Name", systemImage: "doc.on.doc") { Pasteboard.copy(skill.name) }
        }
        #endif
    }
}

/// A card while the skills load: the glyph tile and two lines, in the placeholder fill.
private struct SkillCardPlaceholder: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.primaryText.opacity(contrast == .increased ? 0.16 : 0.08))
                .frame(width: 34, height: 34)
            SkeletonRows(count: 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .frame(minHeight: 118, alignment: .top)
        #else
        .frame(minHeight: 150, alignment: .top)
        #endif
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityHidden(true)
    }
}
