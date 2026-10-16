import HermesKit
import SwiftUI

/// Whose memory a chat's notes are about: the chat's Bot, or Hermes on the gateway.
struct MemoryNoteContext {
    let workspace: BotWorkspace
    let conversation: ConversationModel

    var scope: MemoryModel.Scope { conversation.botName.map { .bot($0) } ?? .hermes }

    func makeModel(tab: MemoryStoreKind = .about) -> MemoryModel {
        let model = MemoryModel(workspace: workspace, scope: scope, newInChat: conversation.memorySaves)
        model.tab = tab
        return model
    }
}

/// The Memory page in a sheet of its own (from a chat's note), owning its model while it's open.
struct MemorySheetPage: View {
    @State private var model: MemoryModel
    @Environment(\.dismiss) private var dismiss

    init(context: MemoryNoteContext, tab: MemoryStoreKind) {
        _model = State(initialValue: context.makeModel(tab: tab))
    }

    var body: some View {
        NavigationStack {
            MemoryView(model: model)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
    }
}

// MARK: - The note under a reply (`memoryNote`, `Memory.memoryNoteUpdated` / `Forgot` / `Waiting`)

/// What the memory tool did in a turn, one quiet line after the reply: "Remembered: …",
/// "Updated memory: …", "Forgot: …", several folded into "Remembered 3 things"; and saves that
/// wait for review, which open Hermes's Notes.
struct MemoryNotes: View {
    let changes: [MemoryChange]
    let context: MemoryNoteContext?

    @State private var shown: NoteSheetItem?
    @State private var showsReview = false

    private struct NoteSheetItem: Identifiable {
        let changes: [MemoryChange]
        var id: String { changes.map(\.id).joined(separator: "|") }
    }

    private var kept: [MemoryChange] { changes.filter { $0.kind != .waiting } }
    private var waiting: [MemoryChange] { changes.filter { $0.kind == .waiting } }

    private var keptLine: String {
        if kept.count == 1, let change = kept.first {
            switch change.kind {
            case .updated: return String(localized: "Updated memory: \(change.text)")
            case .forgot: return String(localized: "Forgot: \(change.text)")
            default: return String(localized: "Remembered: \(change.text)")
            }
        }
        if kept.allSatisfy({ $0.kind == .forgot }) { return String(localized: "Forgot \(kept.count) things") }
        return String(localized: "Remembered \(kept.count) things")
    }

    private var waitingLine: String {
        waiting.count == 1 ? String(localized: "1 memory waiting for your review") : String(localized: "\(waiting.count) memories waiting for your review")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !kept.isEmpty {
                Button {
                    shown = NoteSheetItem(changes: kept)
                } label: {
                    TurnNote(symbol: "brain", text: keptLine)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(context == nil)
                .accessibilityHint("Shows what was remembered")
            }
            if !waiting.isEmpty {
                Button {
                    showsReview = true
                } label: {
                    TurnNote(symbol: "clock", text: waitingLine)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(context == nil)
                .accessibilityHint("Opens Hermes's Notes to review it")
            }
        }
        .sheet(item: $shown) { item in
            if let context { MemoryNoteSheet(changes: item.changes, context: context) }
        }
        .sheet(isPresented: $showsReview) {
            if let context { MemorySheetPage(context: context, tab: .notes) }
        }
    }
}

/// A memory note opened (`memoryNoteSheet`): the entry, which store it's in, Forget and Edit…,
/// and the brain button into Memory.
struct MemoryNoteSheet: View {
    let changes: [MemoryChange]
    let context: MemoryNoteContext

    @State private var model: MemoryModel
    @State private var editing: MemoryEditTarget?
    @State private var forgetting: MemoryEntry?
    @State private var resetting = false
    @State private var showsMemory = false
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif
    @Environment(\.dismiss) private var dismiss

    init(changes: [MemoryChange], context: MemoryNoteContext) {
        self.changes = changes
        self.context = context
        _model = State(initialValue: context.makeModel(tab: changes.first?.store ?? .about))
    }

    private var title: String {
        guard changes.count == 1, let change = changes.first else { return String(localized: "Remembered \(changes.count) things") }
        switch change.kind {
        case .updated: return String(localized: "Updated Memory")
        case .forgot: return String(localized: "Forgot")
        case .waiting: return String(localized: "Waiting for Review")
        case .saved: return String(localized: "Remembered")
        }
    }

    private func caption(_ change: MemoryChange) -> String {
        let store = MemoryCopy.storeLabel(change.store)
        switch change.kind {
        case .saved: return String(localized: "\(store) · saved in this chat")
        case .updated: return String(localized: "\(store) · updated in this chat")
        case .forgot: return String(localized: "\(store) · forgotten in this chat")
        case .waiting: return String(localized: "\(store) · waiting for your review")
        }
    }

    /// The entry as it is on the gateway now, if it's still there.
    private func entry(for change: MemoryChange) -> MemoryEntry? {
        guard change.kind != .forgot else { return nil }
        return model.list?.entry(matching: change.text, in: change.store)
    }

    private func index(of entry: MemoryEntry) -> Int? {
        model.entries(in: entry.store).firstIndex { $0.id == entry.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(changes) { change in
                        card(change)
                    }
                    if changes.count == 1, let change = changes.first {
                        actions(for: change)
                    }
                    Text(changes.contains { $0.kind == .forgot } && changes.count == 1
                         ? String(localized: "\(model.keeperName) won't use this from your next chat.")
                         : String(localized: "\(model.keeperName) uses this from your next chat."))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Memory", systemImage: "brain") { showsMemory = true }
                        .help("Open Memory")
                }
            }
            .navigationDestination(isPresented: $showsMemory) {
                MemoryView(model: model)
            }
        }
        .task { await model.load(includingPending: false) }
        .sheet(item: $editing) { target in
            MemoryEditSheet(model: model, target: target)
        }
        .modifier(MemoryConfirmations(model: model, forgetting: $forgetting, resetting: $resetting))
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: showsMemory) { if showsMemory { detent = .large } }
        #else
        .frame(width: 440, height: 380)
        #endif
    }

    private func card(_ change: MemoryChange) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(change.text)
                    .foregroundStyle(change.kind == .forgot ? Theme.secondaryText : Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption(change))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if changes.count > 1, let entry = entry(for: change) {
                Menu {
                    Button("Edit…", systemImage: "pencil") { editing = MemoryEditTarget(entry: entry, index: index(of: entry)) }
                    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(entry.text) }
                    Divider()
                    Button("Forget", systemImage: "trash", role: .destructive) { forgetting = entry }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(for change: MemoryChange) -> some View {
        if change.kind == .saved || change.kind == .updated {
            let entry = entry(for: change)
            HStack(spacing: 10) {
                Button {
                    forgetting = entry
                } label: {
                    Text("Forget")
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.controlFill, in: Capsule())
                        .contentShape(Capsule())
                }
                Button {
                    if let entry { editing = MemoryEditTarget(entry: entry, index: index(of: entry)) }
                } label: {
                    Text("Edit…")
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.controlFill, in: Capsule())
                        .contentShape(Capsule())
                }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(PressableStyle())
            .disabled(entry == nil || !model.isOnline)
            if model.list != nil, entry == nil {
                Text("It isn't in memory anymore.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - The ask (`Memory.memorySaveAsk`)

/// "Save to memory?": the memory tool asking before it saves (Ask Before Saving on). Docked
/// above the composer in place of the command approval card: Don't Save (deny), Save (once),
/// Save All in This Chat (session). Never Always.
struct MemorySaveAsk: View {
    let approval: ApprovalRequest
    var asker: String = "Hermes"
    let onChoice: (ApprovalChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(
                symbol: "brain",
                tileFill: Theme.surface,
                title: String(localized: "Save to memory?"),
                subtitle: "\(asker) · \(MemoryCopy.storeLabel(approval.memoryStore).lowercased())"
            )
            Text(approval.memoryText)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text("To remember: \(approval.memoryText)"))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    ActionTile(symbol: "xmark", title: String(localized: "Don't Save"), detail: String(localized: "\(asker) carries on"), style: .danger) {
                        onChoice(.deny)
                    }
                    .keyboardShortcut(.cancelAction)
                    ActionTile(symbol: "checkmark", title: String(localized: "Save"), detail: String(localized: "Just this one"), style: .primary) {
                        onChoice(.once)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if approval.choices.contains(.session) {
                    GridRow {
                        ActionTile(symbol: "checkmark.shield.fill", title: String(localized: "Save All in This Chat"), detail: String(localized: "Don't ask again until this chat ends")) {
                            onChoice(.session)
                        }
                        .gridCellColumns(2)
                    }
                }
            }
            Text("\(asker) reads memory at the start of every chat. See and edit it in Memory.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Save to memory?")
    }
}
