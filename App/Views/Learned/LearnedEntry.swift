import HermesKit
import SwiftUI

/// What Hermes Learned wherever it opens from (Skills, Memory): owns the page's model for as
/// long as the page is shown.
struct LearnedHost: View {
    @State private var model: LearnedModel
    var embedded = false
    let onLeave: () -> Void

    init(workspace: BotWorkspace, scope: MemoryModel.Scope = .hermes, embedded: Bool = false, onLeave: @escaping () -> Void) {
        _model = State(initialValue: LearnedModel(workspace: workspace, scope: scope))
        self.embedded = embedded
        self.onLeave = onLeave
    }

    var body: some View {
        LearnedPage(model: model, embedded: embedded)
            .onAppear { model.onLeave = onLeave }
    }
}

/// The top row of Skills (`skills`): "What Hermes Learned", with what's new and when it last
/// tidied.
struct LearnedSkillsRow: View {
    let workspace: BotWorkspace
    var isWide = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                // Ink, like Tools and Apps under it (`skills`).
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 34, height: 34)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What Hermes Learned")
                        .font(.body)
                        .foregroundStyle(Theme.primaryText)
                    Text(workspace.learnedSkillsSubtitle ?? String(localized: "Skills it wrote and things it remembers"))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(isWide ? 14 : 0)
            .background(isWide ? Theme.groupedCell : .clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // Read once per gateway, when Bot Mode is up, and again after a turn writes a skill; pull
        // to refresh on Skills reads it again.
        .task(id: SubtitleTrigger(isConnected: workspace.roster?.isConnected == true, generation: workspace.skillsGeneration)) {
            await workspace.loadLearnedSkillsSubtitle()
        }
    }

    private struct SubtitleTrigger: Equatable {
        let isConnected: Bool
        let generation: Int
    }
}

// MARK: - In a chat

/// "Learned a new skill: app-store-listing" under a reply (`memoryNote` with the sparkles
/// glyph); tapping it opens the skill.
struct LearnedSkillNotes: View {
    let names: [String]
    let context: MemoryNoteContext?

    @State private var opened: OpenedSkill?

    private struct OpenedSkill: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                Button {
                    opened = OpenedSkill(name: name)
                } label: {
                    TurnNote(symbol: "sparkles", text: String(localized: "Learned a new skill: \(name)"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(context == nil)
                .accessibilityHint("Opens the skill")
            }
        }
        .sheet(item: $opened) { skill in
            if let context { LearnedSkillSheet(context: context, skillID: skill.name) }
        }
    }
}

/// A learned skill in a sheet of its own (from a chat's note).
struct LearnedSkillSheet: View {
    @State private var model: LearnedModel
    let skillID: String
    @Environment(\.dismiss) private var dismiss

    init(context: MemoryNoteContext, skillID: String) {
        _model = State(initialValue: LearnedModel(workspace: context.workspace, scope: context.scope))
        self.skillID = skillID
    }

    var body: some View {
        NavigationStack {
            LearnedSkillPage(model: model, skillID: skillID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .onAppear { model.onLeave = { dismiss() } }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #endif
    }
}
