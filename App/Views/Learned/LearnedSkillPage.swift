import HermesKit
import SwiftUI

/// A learned skill (`learnedSkill`): where it came from and its use, Keep As Is, what it's
/// connected to, its SKILL.md, and a bottom glass bar with Archive and Use in a Chat.
struct LearnedSkillPage: View {
    let model: LearnedModel
    let skillID: String

    @State private var text: String?
    @State private var confirmsArchive = false
    @State private var editing = false
    @State private var openedMemory: LearningNode?
    @State private var copied = false
    /// iPad: the SKILL.md in the Inspector's File tab, in a sheet.
    @State private var inspectorTarget: LearnedModel.InspectorTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow

    private var skill: LearningNode? { model.node(skillID) }

    var body: some View {
        Group {
            if let skill {
                content(skill)
            } else if model.isLoading {
                SkeletonRows()
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                StateMessage(symbol: "archivebox", title: String(localized: "\(skillID) isn't here anymore"),
                             message: String(localized: "It may have been archived or merged. Tidying can restore it."))
            }
        }
        .background(Theme.groupedBackground)
        .navigationTitle(skill?.label ?? skillID)
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit", systemImage: "pencil") { edit() }
                        .disabled(text == nil)
                    Button(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") {
                        if let text { Pasteboard.copy(text); copied = true }
                    }
                    .disabled(text == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .task(id: skillID) {
            if model.graph == nil { await model.load() }
            if let skill { text = await model.text(of: skill) }
            #if DEBUG
            // `-HERMES_LEARNED_EDIT YES` with `-HERMES_LEARNED skill:<id>` runs Edit (screenshots).
            if text != nil, UserDefaults.standard.bool(forKey: "HERMES_LEARNED_EDIT") { edit() }
            #endif
        }
        .sheet(isPresented: $editing) {
            if let skill { LearnedSkillEditor(model: model, skill: skill, text: $text) }
        }
        .sheet(item: $openedMemory) { memory in
            LearnedMemorySheet(model: model, memory: memory)
        }
        .sheet(item: $inspectorTarget, onDismiss: {
            // What was saved there is the skill's text now.
            Task { if let skill { text = await model.text(of: skill) } }
        }) { target in
            NavigationStack {
                InspectorPanel(inspector: target.conversation.inspector, conversation: target.conversation, workspace: model.workspace,
                               style: .window, onlyTab: target.tabID)
                    .navigationTitle("SKILL.md")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { inspectorTarget = nil }
                        }
                    }
            }
        }
        .confirmationDialog(String(localized: "Archive \(skill?.label ?? skillID)?"), isPresented: $confirmsArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                guard let skill else { return }
                Task {
                    if await model.archive(skill) { dismiss() }
                }
            }
        } message: {
            Text("Hermes stops using it. You can restore it from Tidying.")
        }
        .modifier(LearnedMessages(model: model))
    }

    private func content(_ skill: LearningNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LearnedMacTitle(title: skill.label)
                facts(skill)
                keepAsIs(skill)
                let connections = model.connections(of: skill.id)
                if !connections.isEmpty {
                    LearnedSectionTitle(title: String(localized: "Connected"))
                    LearnedCard {
                        ForEach(connections) { other in
                            connectionRow(other)
                        }
                    }
                }
                LearnedSectionTitle(title: "SKILL.md")
                skillText
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 110)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom) {
            bottomBar(skill)
        }
    }

    // MARK: Facts

    private func facts(_ skill: LearningNode) -> some View {
        LearnedCard {
            fact(String(localized: "Made by"), madeBy(skill))
            fact(String(localized: "Used"), used(skill))
            fact(String(localized: "Category"), LearningMapView.categoryName(skill.category))
            if skill.state != .active {
                fact(String(localized: "State"), skill.state == .stale ? String(localized: "Stale") : String(localized: "Archived"))
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.primaryText)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// "Hermes, Sep 18" / "You with /learn, Sep 18". The gateway doesn't keep the chat a skill
    /// was written in, so the date stands in.
    private func madeBy(_ skill: LearningNode) -> String {
        let who = switch skill.createdBy {
        case "agent": String(localized: "Hermes")
        case "learn": String(localized: "You, with /learn")
        default: String(localized: "Used by Hermes")
        }
        guard let date = skill.learnedAt else { return who }
        return "\(who), \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func used(_ skill: LearningNode) -> String {
        let times = skill.useCount == 0 ? String(localized: "Not yet") : (skill.useCount == 1 ? String(localized: "Once") : String(localized: "\(skill.useCount) times"))
        guard skill.useCount > 0, let date = skill.date else { return times }
        return "\(times) · \(Formatting.relativePhrase(date))"
    }

    // MARK: Keep As Is

    private func keepAsIs(_ skill: LearningNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep As Is").font(.body).foregroundStyle(Theme.primaryText)
                    Text("Tidying won't merge, change or archive it")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.busy.contains(skill.id) {
                    Spinner()
                }
                Toggle("Keep As Is", isOn: Binding(
                    get: { skill.pinned },
                    set: { pinned in Task { await model.setPinned(skill, pinned) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.busy.contains(skill.id) || !model.isOnline)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text("Pinned skills are left alone when Hermes tidies up.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
        }
    }

    // MARK: Connections

    @ViewBuilder
    private func connectionRow(_ other: LearningNode) -> some View {
        if other.isSkill {
            NavigationLink(value: LearnedRoute.skill(other.id)) {
                LearnedSkillRow(skill: other, subtitle: other.useCount == 1 ? String(localized: "Related skill · used once") : String(localized: "Related skill · used \(other.useCount) times"))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                openedMemory = other
            } label: {
                HStack(spacing: 12) {
                    LearnedGlyph(symbol: "brain")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(other.label)
                            .font(.body)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(2)
                        Text(other.memorySource == "profile" ? String(localized: "Memory · About you") : String(localized: "Memory · Hermes's notes"))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
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
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: SKILL.md

    @ViewBuilder
    private var skillText: some View {
        if let text {
            Text(String(text.prefix(1600)))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(14)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture { edit() }
                .accessibilityAction(named: Text("Edit")) { edit() }
        } else {
            SkeletonRows(count: 3, twoLines: false)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    /// Edit: the Inspector's File tab on iPad and the Mac (its own window on the Mac); a code
    /// editor sheet on iPhone.
    private func edit() {
        #if os(macOS)
        Task {
            if let target = await model.openInInspector(skillID) {
                target.conversation.inspector.detach(target.tabID)
                openWindow(value: InspectorWindowRef(workspaceID: model.workspace.id, conversationID: target.conversation.id, tabID: target.tabID))
            } else {
                editing = true
            }
        }
        #else
        if sizeClass == .regular {
            Task {
                if let target = await model.openInInspector(skillID) {
                    inspectorTarget = target
                } else {
                    editing = true
                }
            }
        } else {
            editing = true
        }
        #endif
    }

    // MARK: Bottom bar

    private func bottomBar(_ skill: LearningNode) -> some View {
        HStack(spacing: 10) {
            Button {
                confirmsArchive = true
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(skill.state == .archived || model.busy.contains(skill.id) || skill.pinned)
            Button {
                model.useInChat(skill)
            } label: {
                Label("Use in a Chat", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .prominentGlassButton()
            .buttonBorderShape(.capsule)
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: 720)
    }
}

/// Editing a SKILL.md where the Inspector isn't (iPhone, or a gateway that won't say where the
/// file is): the code editor, saved with `PUT /api/learning/node`.
struct LearnedSkillEditor: View {
    let model: LearnedModel
    let skill: LearningNode
    @Binding var text: String?

    @State private var draft = ""
    @State private var isSaving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.dangerWash)
                }
                CodeTextView(text: $draft, language: "markdown", isEditable: true,
                             changedLines: CodeTextView.changedLines(from: text ?? "", to: draft))
            }
            .navigationTitle(skill.label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || draft == text || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { draft = text ?? "" }
        #if os(macOS)
        .frame(width: 640, height: 560)
        #endif
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if let failure = await model.save(skill, content: draft, expected: text ?? "") {
            error = failure
        } else {
            text = draft
            dismiss()
        }
    }
}
