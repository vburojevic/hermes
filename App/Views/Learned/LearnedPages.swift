import HermesKit
import SwiftUI

/// Where What Hermes Learned goes from its page.
enum LearnedRoute: Hashable {
    case map
    case skill(String)
    case tidying
}

/// What Hermes Learned (`learnedPage`; `ipadLearned`, `macLearned`): the story, New This Week,
/// the map, Most Used and Tidying on iPhone; on iPad and the Mac the map fills the main space
/// with the selected skill under it, the story and tidying beside it.
struct LearnedPage: View {
    let model: LearnedModel
    /// Set when the page sits inside another screen (Skills on the Mac): no title of its own.
    var embedded = false

    /// A page pushed from code (Open Skill under the map).
    @State private var pushed: LearnedRoute?
    @State private var openedMemory: LearningNode?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if model.graph == nil, model.workspace.botModeIsDown {
                BotModeSetupMessage(workspace: model.workspace, feature: GatewaySetup.ID.learned,
                                    title: String(localized: "What \(model.learnerName) Learned"), symbol: "sparkles")
            } else if model.graph == nil, let error = model.loadError {
                StateMessage(symbol: "sparkles", title: String(localized: "What \(model.learnerName) learned isn't available"), message: error,
                             actionTitle: model.needsBotMode ? nil : String(localized: "Try Again")) { Task { await model.load() } }
            } else if model.graph == nil {
                Spinner(size: .regular).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isWide {
                wide
            } else {
                list
            }
        }
        .background(Theme.groupedBackground)
        .navigationTitle(embedded ? "" : String(localized: "What \(model.learnerName) Learned"))
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Tidying", systemImage: "wand.and.sparkles") { pushed = .tidying }
                    Button("Tidy Up Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.tidyUpNow() }
                    }
                    .disabled(model.isTidying || !model.isOnline)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        #endif
        .task(id: model.isOnline) {
            await model.load()
            openPendingRoute()
            #if DEBUG
            if model.graph != nil { openDebugRoute() }
            #endif
        }
        .onChange(of: model.workspace.pendingLearnedRoute) { openPendingRoute() }
        .refreshable { await model.load() }
        .navigationDestination(for: LearnedRoute.self) { route in
            Self.page(for: route, model: model)
        }
        .navigationDestination(item: $pushed) { route in
            Self.page(for: route, model: model)
        }
        .sheet(item: $openedMemory) { memory in
            LearnedMemorySheet(model: model, memory: memory)
        }
        .modifier(LearnedMessages(model: model))
    }

    @ViewBuilder
    static func page(for route: LearnedRoute, model: LearnedModel) -> some View {
        switch route {
        case .map: LearnedMapPage(model: model)
        case .skill(let id): LearnedSkillPage(model: model, skillID: id)
        case .tidying: LearnedTidyingPage(model: model)
        }
    }

    /// The page a notification asked for (Tidying after a tidy).
    private func openPendingRoute() {
        guard let route = model.workspace.pendingLearnedRoute else { return }
        model.workspace.pendingLearnedRoute = nil
        pushed = route
    }

    #if DEBUG
    /// `-HERMES_LEARNED map|tidying|skill:<id>|select:<id>` (screenshots).
    private func openDebugRoute() {
        guard let route = UserDefaults.standard.string(forKey: "HERMES_LEARNED"), pushed == nil else { return }
        if route == "map" { pushed = .map }
        if route == "tidying" { pushed = .tidying }
        if route.hasPrefix("skill:") { pushed = .skill(String(route.dropFirst(6))) }
        if route.hasPrefix("select:") { model.selectedID = String(route.dropFirst(7)) }
        if route.hasPrefix("mapselect:") {
            model.selectedID = String(route.dropFirst(10))
            pushed = .map
        }
    }
    #endif

    // MARK: iPhone

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LearnedHero(model: model)
                if !model.newThisWeek.isEmpty {
                    LearnedSectionTitle(title: String(localized: "New This Week"))
                    LearnedCard {
                        ForEach(model.newThisWeek) { skill in
                            NavigationLink(value: LearnedRoute.skill(skill.id)) {
                                LearnedSkillRow(skill: skill, subtitle: newSubtitle(skill), badge: .new)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                NavigationLink(value: LearnedRoute.map) {
                    VStack(spacing: 8) {
                        LearningMapView(model: model, isPreview: true)
                            .frame(height: 250)
                            .accessibilityHidden(true)
                        HStack {
                            Text("How skills and memories connect · tap to explore")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                    .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("The Map: how skills and memories connect"))
                    .accessibilityAddTraits(.isButton)
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 4)
                if !model.mostUsed.isEmpty {
                    LearnedSectionTitle(title: String(localized: "Most Used"))
                    LearnedCard {
                        ForEach(model.mostUsed.prefix(3)) { skill in
                            NavigationLink(value: LearnedRoute.skill(skill.id)) {
                                LearnedSkillRow(skill: skill, subtitle: model.summary(of: skill), badge: skill.state == .stale ? .stale : .none)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LearnedCard {
                    NavigationLink(value: LearnedRoute.tidying) {
                        HStack(spacing: 12) {
                            LearnedGlyph(symbol: "wand.and.sparkles")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tidying").font(.body).foregroundStyle(Theme.primaryText)
                                Text(model.lastTidySentence)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func newSubtitle(_ skill: LearningNode) -> String {
        let when = skill.learnedAt.map { Formatting.relativePhrase($0) } ?? ""
        let who = skill.createdBy == "learn" ? String(localized: "You taught it with /learn") : String(localized: "Hermes wrote it")
        return when.isEmpty ? who : "\(who) · \(when)"
    }

    // MARK: iPad and Mac

    private var wide: some View {
        GeometryReader { geometry in
            let side = min(max(geometry.size.width * 0.36, 320), 460)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    #if os(macOS)
                    // The Mac draws its own large title (`macLearned`).
                    Text("What \(model.learnerName) Learned")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    #else
                    Text(model.mapIntro)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    #endif
                    ZStack(alignment: .topTrailing) {
                        LearningMapView(model: model) { openedMemory = $0 }
                            .background(Theme.groupedCell)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        LearnedMapFilters(model: model)
                            .padding(12)
                    }
                    .frame(maxHeight: .infinity)
                    if let id = model.selectedID, let skill = model.node(id) {
                        LearnedCallout(model: model, skill: skill, wide: true) {
                            pushed = .skill(id)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        LearnedHero(model: model, compact: true)
                        if !model.newThisWeek.isEmpty || !model.staleSkills.isEmpty {
                            LearnedSectionTitle(title: String(localized: "New This Week"))
                            LearnedCard {
                                ForEach(model.newThisWeek) { skill in
                                    NavigationLink(value: LearnedRoute.skill(skill.id)) {
                                        LearnedSkillRow(skill: skill, subtitle: newSubtitle(skill), badge: .new)
                                    }
                                    .buttonStyle(.plain)
                                }
                                ForEach(model.staleSkills.prefix(2)) { skill in
                                    NavigationLink(value: LearnedRoute.skill(skill.id)) {
                                        LearnedSkillRow(skill: skill, subtitle: staleSubtitle(skill), badge: .stale)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        NavigationLink(value: LearnedRoute.tidying) {
                            CuratorCard(model: model, showsCounts: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: side)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .animation(Theme.snappy, value: model.selectedID)
        }
    }

    private func staleSubtitle(_ skill: LearningNode) -> String {
        let days = skill.date.map { max(0, Int(Date.now.timeIntervalSince($0) / 86_400)) }
        let archiveAfter = model.curator?.archiveAfterDays ?? 90
        if let days { return String(localized: "Unused for \(days) days · archived after \(archiveAfter)") }
        return String(localized: "Unused · archived after \(archiveAfter) days")
    }
}

/// The map's filter chips: All, Skills, Memories, and one per category.
struct LearnedMapFilters: View {
    let model: LearnedModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "All"), .all)
                chip(String(localized: "Skills"), .skills)
                chip(String(localized: "Memories"), .memories)
                ForEach(model.graph?.skillCategories ?? [], id: \.self) { category in
                    chip(LearningMapView.categoryName(category), .category(category))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ title: String, _ filter: LearnedModel.MapFilter) -> some View {
        Button {
            withAnimation(Theme.snappy) { model.filter = filter }
        } label: {
            ChipLabel(title: title, isActive: model.filter == filter)
                .background(model.filter == filter ? Color.clear : Theme.groupedCell, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
    }
}

/// The selected skill under the map: name, category, what it does and its use; Show
/// Connections / Keep As Is and Open Skill.
struct LearnedCallout: View {
    let model: LearnedModel
    let skill: LearningNode
    var wide = false
    let open: () -> Void

    @State private var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(skill.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                TagLabel(title: LearningMapView.categoryName(skill.category))
            }
            Text(sentence)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if wide {
                    Spacer()
                    Button(skill.pinned ? "Kept As Is" : "Keep As Is") {
                        Task { await model.setPinned(skill, !skill.pinned) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .cardButton()
                    .controlSize(.large)
                    .disabled(model.busy.contains(skill.id))
                } else {
                    Button {
                        withAnimation(Theme.snappy) { model.filter = .all }
                    } label: {
                        // Its natural width (it would wrap at half); Open Skill takes the rest.
                        Text("Show Connections").lineLimit(1).fixedSize()
                    }
                    .font(.subheadline.weight(.semibold))
                    .cardButton()
                    .controlSize(.large)
                }
                Button(action: open) {
                    Text("Open Skill").frame(maxWidth: wide ? nil : .infinity)
                }
                .font(.subheadline.weight(.semibold))
                .learnedPrimaryButton()
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: skill.id) {
            description = nil
            if let text = await model.text(of: skill) { description = SkillText.description(text) }
        }
    }

    /// "Runs the iOS tests on Studio Mac… Used 12 times; 2 memories mention it."
    private var sentence: String {
        var parts: [String] = []
        if let description, !description.isEmpty { parts.append(description.hasSuffix(".") ? description : description + ".") }
        var uses = skill.useCount == 1 ? String(localized: "Used once") : String(localized: "Used \(skill.useCount) times")
        // Beside the map there's room for where it came from: "Hermes wrote it on Sep 18; used 12 times".
        if wide, skill.createdBy != nil, let made = skill.learnedAt {
            let lowered = uses.prefix(1).lowercased() + uses.dropFirst()
            uses = String(localized: "\(model.madeBy(skill)) on \(made.formatted(.dateTime.month(.abbreviated).day())); \(lowered)")
        }
        let memoryLinks = model.connections(of: skill.id).filter { !$0.isSkill }.count
        if memoryLinks > 0 {
            parts.append(memoryLinks == 1 ? String(localized: "\(uses); 1 memory mentions it.") : String(localized: "\(uses); \(memoryLinks) memories mention it."))
        } else {
            parts.append(uses + ".")
        }
        return parts.joined(separator: " ")
    }
}

/// A SKILL.md's frontmatter description, or its first line of prose.
enum SkillText {
    static func description(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                if line.lowercased().hasPrefix("description:") {
                    return String(line.dropFirst("description:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
            }
        }
        var inFrontmatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFrontmatter {
                if index > 0, trimmed == "---" { inFrontmatter = false }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return trimmed
        }
        return ""
    }
}

// MARK: - The full map (`learnedMap`)

struct LearnedMapPage: View {
    let model: LearnedModel
    @State private var openedMemory: LearningNode?
    @State private var path: LearnedRoute?
    /// Search selects the first skill whose name matches.
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LearnedMacTitle(title: String(localized: "Map"))
                .padding(.horizontal, 16)
            LearnedMapFilters(model: model)
                .padding(.horizontal, 16)
            LearningMapView(model: model) { openedMemory = $0 }
                .frame(maxHeight: .infinity)
            if let id = model.selectedID, let skill = model.node(id) {
                LearnedCallout(model: model, skill: skill) { path = .skill(id) }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 12)
        .background(Theme.canvas)
        .navigationTitle("Map")
        .searchable(text: $query, placement: .toolbar, prompt: Text("Find a skill"))
        #if os(iOS)
        .searchToolbarBehavior(.minimize)
        #endif
        .onChange(of: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let match = (model.graph?.skills ?? []).first(where: { $0.label.localizedCaseInsensitiveContains(text) && model.isShown($0) }) else { return }
            model.selectedID = match.id
        }
        .animation(Theme.snappy, value: model.selectedID)
        .navigationDestination(item: $path) { route in
            if case .skill(let id) = route { LearnedSkillPage(model: model, skillID: id) }
        }
        .sheet(item: $openedMemory) { memory in
            LearnedMemorySheet(model: model, memory: memory)
        }
    }
}

/// A memory tapped on the map: the Memory page of the same Bot, on the entry's store.
struct LearnedMemorySheet: View {
    let model: LearnedModel
    let memory: LearningNode

    @State private var memoryModel: MemoryModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let memoryModel {
                    MemoryView(model: memoryModel)
                } else {
                    Spinner(size: .regular)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .onAppear {
            let model = MemoryModel(workspace: model.workspace, scope: model.scope)
            model.tab = memory.memorySource.flatMap(MemoryStoreKind.init(source:)) ?? .notes
            memoryModel = model
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
    }
}

/// Messages and toasts from the model, as alerts.
struct LearnedMessages: ViewModifier {
    let model: LearnedModel

    func body(content: Content) -> some View {
        content
            .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation(Theme.snappy) { model.toast = nil }
                        }
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(Theme.snappy, value: model.toast)
    }
}
