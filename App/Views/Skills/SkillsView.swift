import HermesKit
import SwiftUI

/// What this Hermes can do: its skills and tool sets.
struct SkillsView: View {
    let workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    @State private var skills: [Skill] = []
    @State private var toolsets: [Toolset] = []
    @State private var skillsError: HermesError?
    @State private var toolsetsError: HermesError?
    @State private var isLoading = false
    @State private var query = ""

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

    var body: some View {
        List {
            if isLoading && skills.isEmpty && toolsets.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            if !toolsets.isEmpty && query.isEmpty {
                Section {
                    ForEach($toolsets) { $toolset in
                        ToolsetRow(toolset: $toolset, roster: canConfigureTools ? workspace.roster : nil)
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text(canConfigureTools ? String(localized: "Changes apply to new chats on this gateway.") : String(localized: "Change tool sets with `hermes tools` on the gateway."))
                }
            } else if let toolsetsError, query.isEmpty {
                Section("Tools") {
                    Text(toolsetsError.errorDescription ?? "")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if let skillsError, skills.isEmpty {
                Section("Skills") {
                    Text("This Hermes version couldn't list its skills. \(skillsError.errorDescription ?? "")")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            ForEach(groupedSkills, id: \.0) { category, skills in
                Section(category) {
                    ForEach(skills) { skill in
                        SkillRow(skill: skill) {
                            useSkill(skill)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        #if os(iOS)
        .searchable(text: $query, placement: .toolbar, prompt: "Search Skills")
        #else
        .searchable(text: $query, prompt: "Search skills")
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

    private func load() async {
        guard let client = workspace.client else { return }
        isLoading = true
        defer { isLoading = false }
        async let loadedSkills = client.skills()
        async let loadedToolsets = client.toolsets()
        do {
            skills = try await loadedSkills
            skillsError = nil
        } catch {
            skillsError = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
        do {
            toolsets = try await loadedToolsets
            toolsetsError = nil
        } catch {
            toolsetsError = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
    }

    /// Tool sets switch on and off over the gateway protocol (`tools.configure`).
    private var canConfigureTools: Bool {
        workspace.roster?.state.isOnline == true
    }

    /// A new chat with the skill as a chip, over the gateway protocol; otherwise in words.
    private func useSkill(_ skill: Skill) {
        workspace.startNewChat()
        guard let draft = workspace.draft else { return }
        if draft.usesGateway {
            draft.skills = [skill.name]
        } else {
            draft.draft = "Use the \(skill.name) skill to "
        }
    }
}

private struct SkillRow: View {
    let skill: Skill
    let onUse: () -> Void

    private var symbol: String {
        switch skill.category?.lowercased() ?? "" {
        case let c where c.contains("research"): "doc.text.magnifyingglass"
        case let c where c.contains("dev") || c.contains("software"): "chevron.left.forwardslash.chevron.right"
        case let c where c.contains("ops") || c.contains("devops"): "server.rack"
        case let c where c.contains("creative") || c.contains("design"): "paintbrush"
        case let c where c.contains("productivity"): "checklist"
        case let c where c.contains("media"): "play.rectangle"
        default: "book.closed"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .accessibilityLabel("Use \(skill.name) in a new chat")
        }
        .padding(.vertical, 4)
    }
}

/// A tool set with its switch (`skills`): live over the gateway protocol, read-only otherwise.
private struct ToolsetRow: View {
    @Binding var toolset: Toolset
    /// Set when the gateway protocol can change it.
    let roster: BotRoster?

    @State private var isSaving = false

    private var isOn: Binding<Bool> {
        Binding(get: { toolset.enabled != false }, set: { save($0) })
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toolset.label ?? toolset.name)
                    .foregroundStyle(Theme.primaryText)
                if let description = toolset.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.success)
        .disabled(roster == nil || isSaving)
        .help((toolset.tools ?? []).joined(separator: ", "))
        .accessibilityHint(roster == nil ? Text("Change it with hermes tools on the gateway") : Text(""))
    }

    private func save(_ enabled: Bool) {
        guard let roster else { return }
        let previous = toolset.enabled
        toolset.enabled = enabled
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await roster.request("tools.configure", [
                    "action": .string(enabled ? "enable" : "disable"),
                    "names": .array([.string(toolset.name)]),
                ])
            } catch {
                toolset.enabled = previous
            }
        }
    }
}
