import HermesKit
import SwiftUI

/// What this Hermes knows how to do (`screens/iphone/skills.elyx`, `screens/ipad/skills.elyx`,
/// `screens/mac/skills.elyx`): Tools and Apps first (managed in Settings), then the skills by
/// category, as rows on iPhone and a grid of cards on iPad and Mac. Use puts a skill in the
/// composer's tray (`docs/bots-groups-skills.md`).
struct SkillsView: View {
    let workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    @State private var skills: [Skill] = []
    @State private var skillsError: HermesError?
    @State private var isLoading = false
    /// The window's skill filter, kept with the window.
    @SceneStorage("skills.query") private var query = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(WindowRouter.self) private var router: WindowRouter?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var filteredSkills: [Skill] {
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var groupedSkills: [(String, [Skill])] {
        Dictionary(grouping: filteredSkills) { $0.category?.replacingOccurrences(of: "-", with: " ").capitalized ?? String(localized: "General") }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
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
            if usesGrid { grid } else { list }
        }
        .background(Theme.canvas)
        #if os(iOS)
        .searchable(text: $query, placement: .toolbar, prompt: usesGrid ? "Search skills" : "Search Skills")
        #else
        .searchable(text: $query, placement: .toolbar, prompt: "Search skills")
        #endif
        .navigationTitle("Skills")
        .toolbar {
            if let onToggleSidebar {
                ToolbarItem(placement: .navigation) {
                    Button(action: onToggleSidebar) { SidebarGlyph() }
                        .accessibilityLabel("Show sidebar")
                }
            }
        }
        .task(id: workspace.id) { await load() }
        .onChange(of: workspace.pendingSkillQuery, initial: true) { _, pending in
            // Show Skill on a skill chip opens Skills filtered to it.
            guard let pending else { return }
            query = pending
            workspace.pendingSkillQuery = nil
        }
        .refreshable { await load() }
        .overlay {
            if !query.isEmpty && filteredSkills.isEmpty && !skills.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    // MARK: iPhone

    private var list: some View {
        List {
            if query.isEmpty {
                Section {
                    ToolsAndAppsRow(model: workspace.appsAndTools, isWide: false, action: openAppsAndTools)
                } footer: {
                    Text("Skills teach Hermes how to do things; tools and apps are what it can reach. Manage those in Settings → Apps and Tools.")
                }
            }
            loadingAndErrors
            ForEach(groupedSkills, id: \.0) { category, skills in
                Section(category) {
                    ForEach(skills) { skill in
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
                    ToolsAndAppsRow(model: workspace.appsAndTools, isWide: true, action: openAppsAndTools)
                        .padding(.bottom, 8)
                }
                loadingAndErrors
                ForEach(groupedSkills, id: \.0) { category, skills in
                    Text(category)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(skills) { skill in
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

    @ViewBuilder
    private var loadingAndErrors: some View {
        if isLoading && skills.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
        if let skillsError, skills.isEmpty {
            Text("This Hermes version couldn't list its skills. \(skillsError.errorDescription ?? "")")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func load() async {
        guard let client = workspace.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            skills = try await client.skills()
            skillsError = nil
        } catch {
            skillsError = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
        if workspace.roster?.isConnected == true, !workspace.appsAndTools.hasLoaded {
            await workspace.appsAndTools.load()
        }
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 34, height: 34)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools and Apps")
                        .foregroundStyle(Theme.primaryText)
                    Text(isWide ? model.toolsSummary + " · " + String(localized: "managed in Settings") : model.toolsSummary)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: SkillGlyph.symbol(for: skill))
                .font(.system(size: 14, weight: .medium))
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
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: SkillGlyph.symbol(for: skill))
                    .font(.system(size: 14, weight: .medium))
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
                .lineLimit(1)
                .padding(.top, 4)
            Text(skill.description ?? "")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .frame(minHeight: 118, alignment: .top)
        #else
        .frame(minHeight: 150, alignment: .top)
        #endif
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
