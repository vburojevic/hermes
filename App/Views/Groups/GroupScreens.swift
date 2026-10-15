import HermesKit
import SwiftUI

/// A hosted group chat (`screens/*/group-chat.elyx`, `screens/mac/groups.elyx`): the Bots take
/// turns on the person's message in rounds, and the room settles when nobody has more to add.
struct GroupChatScreen: View {
    @Bindable var chat: GroupChatModel
    let rooms: GroupRooms
    let workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    @State private var showsActivity = false
    @State private var showsSettings = false
    @State private var composerFocused = false

    private var roster: BotRoster? { workspace.roster }

    private func appearance(_ memberID: String) -> BotAppearance? {
        guard let roster, let member = chat.member(memberID), let bot = roster.bot(named: member.profile) else { return nil }
        return roster.appearance(for: bot)
    }

    private func name(_ memberID: String) -> String {
        guard let member = chat.member(memberID) else { return memberID }
        return roster?.bot(named: member.profile)?.title ?? member.displayName ?? member.handle
    }

    /// The room's members (and the gateway's other Bots) are face pills where they're named.
    private var references: ReferenceContext {
        var handles = Set<String>()
        for member in chat.room.members {
            handles.insert(member.handle.lowercased())
            handles.insert(member.profile.lowercased())
        }
        return ReferenceContext(workspace: workspace, catalog: workspace.slashCatalog(profile: nil), extraHandles: handles)
    }

    /// Who's still to answer this round, while the room works.
    private var waiting: [GroupRoom.Member] {
        guard chat.isWorking else { return [] }
        let states = chat.memberStates
        return chat.room.members.filter { states[$0.memberID] == nil }
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            transcript
        }
        .safeAreaBar(edge: .bottom) { bottomBar }
        .toolbar { toolbar }
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .navigationTitle(chat.room.name)
        .toolbarTitleDisplayMode(.inline)
        .onAppear { chat.open() }
        .onDisappear { chat.close() }
        .sheet(isPresented: $showsActivity) {
            GroupActivityView(chat: chat, workspace: workspace)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSettings) {
            GroupSettingsSheet(chat: chat, rooms: rooms, workspace: workspace)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if chat.items.isEmpty {
                    VStack(spacing: 12) {
                        MemberStack(appearances: chat.room.members.compactMap { appearance($0.memberID) }, size: 44)
                        Text(chat.room.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text("Each Bot replies only when it has something new to add. Mention one with @ to ask just them.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                ForEach(chat.items) { item in
                    row(item)
                }
                if !waiting.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(waiting.count == 1 ? String(localized: "\(name(waiting[0].memberID)) is replying…") : String(localized: "Bots are replying…"))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                if let error = chat.error {
                    TurnNote(symbol: "exclamationmark.triangle", text: error, tint: Theme.warning)
                }
            }
            .frame(maxWidth: Theme.readableWidth)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .environment(\.references, references)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .animation(Theme.spring, value: chat.items)
    }

    @ViewBuilder
    private func row(_ item: RoomItem) -> some View {
        switch item {
        case .user(_, let text, _):
            let parts = references.parts(of: text, leading: false)
            Group {
                if parts.references.isEmpty {
                    Text(text).font(Theme.Typography.message)
                } else {
                    InlineFlow(parts: parts)
                }
            }
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 56)
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) } }
                .accessibilityElement(children: .combine)
        case .member(_, let memberID, let text, let date):
            MemberMessageRow(appearance: appearance(memberID), name: name(memberID), isLead: chat.room.members.first?.memberID == memberID, date: date, text: text)
        case .passed(_, let memberID):
            MemberPassedRow(appearance: appearance(memberID), name: name(memberID))
        case .failed(_, let memberID, let error):
            TurnNote(symbol: "exclamationmark.triangle", text: String(localized: "\(name(memberID)) couldn't reply · \(error)"), tint: Theme.warning)
        case .round(_, let index):
            RoundDivider(text: String(localized: "Round \(index + 1) of \(RoomTranscript.maxRounds)"))
        case .settled(_, let rounds, let bounded):
            RoundDivider(text: bounded ? String(localized: "Room paused · reached its limit") : rounds == 1 ? String(localized: "Room settled · 1 round") : String(localized: "Room settled · \(rounds) rounds"))
        case .renamed(_, let name):
            RoundDivider(text: String(localized: "Renamed to \(name)"))
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let approval = chat.pendingApproval {
                ApprovalCard(approval: approval.request, asker: name(approval.memberID)) { choice in
                    chat.respond(choice)
                }
                .transition(.opacity)
            } else if chat.retryTask != nil {
                HStack {
                    Label("A Bot's turn didn't finish.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Retry", action: chat.retry)
                        .cardButton()
                        .controlSize(.small)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            GroupComposer(chat: chat, roster: roster, workspace: workspace, focused: $composerFocused)
        }
        .frame(maxWidth: Theme.readableWidth + 40)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(Theme.spring, value: chat.pendingApproval)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onToggleSidebar {
            ToolbarItem(placement: .navigation) {
                Button(action: onToggleSidebar) { SidebarGlyph() }
                    .accessibilityLabel("Show sidebar")
            }
        }
        ToolbarItem(placement: .principal) {
            GroupTitle(chat: chat, roster: roster)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showsActivity = true } label: { Image(systemName: "person.3") }
                .accessibilityLabel("Activity")
                .help("Activity")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Group settings")
                .help("Group settings")
        }
    }
}

/// The room's avatar, name and live status in the toolbar (`groupTitle`).
private struct GroupTitle: View {
    let chat: GroupChatModel
    let roster: BotRoster?

    private var status: (String, Color) {
        if chat.pendingApproval != nil { return (String(localized: "Needs you"), Theme.warning) }
        if chat.isWorking { return (String(localized: "Round \(chat.currentRound) of \(RoomTranscript.maxRounds) · replying…"), Theme.warning) }
        return (String(localized: "\(chat.room.members.count) Bots"), Theme.secondaryText)
    }

    var body: some View {
        let faces = chat.room.members.prefix(4).compactMap { member in
            roster?.bot(named: member.profile).map { GroupFaceStack.Face(id: member.memberID, appearance: roster!.appearance(for: $0)) }
        }
        let passed = Set(chat.memberStates.filter { $0.value == .passed }.map(\.key))
        HStack(spacing: 8) {
            // Everyone looks at who's talking (`docs/bot-faces.md` §5.2).
            GroupFaceStack(faces: faces, active: chat.activeMemberID, passed: passed, handOff: chat.lastHandOff, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(chat.room.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(status.0)
                    .font(.caption2)
                    .foregroundStyle(status.1)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .animation(Theme.snappy, value: status.0)
        .accessibilityElement(children: .combine)
    }
}

/// The group's composer: the same glass panel as a chat's, Send or Stop. `@` lists the room's
/// members; a picked one is a face pill in the text.
private struct GroupComposer: View {
    @Bindable var chat: GroupChatModel
    let roster: BotRoster?
    let workspace: BotWorkspace
    var focused: Binding<Bool>

    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @State private var field = PillTextController()
    @State private var selection: String?
    @State private var dismissedQueryStart: Int?
    @State private var peek: PillPeek?

    private var hasText: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var context: ReferenceContext {
        var handles = Set<String>()
        for member in chat.room.members {
            handles.insert(member.handle.lowercased())
            handles.insert(member.profile.lowercased())
        }
        return ReferenceContext(workspace: workspace, catalog: nil, extraHandles: handles)
    }

    /// Members matching the `@word` being typed.
    private var members: [GroupRoom.Member] {
        guard let query = field.query, query.trigger == "@", query.range.location != dismissedQueryStart else { return [] }
        let text = query.text.lowercased()
        return chat.room.members.filter { text.isEmpty || $0.handle.lowercased().hasPrefix(text) || $0.profile.lowercased().hasPrefix(text) }
    }

    private var choices: [SlashChoice] {
        guard let roster else { return [] }
        return members.compactMap { member in
            roster.bot(named: member.profile).map { SlashChoice.bot($0, roster.appearance(for: $0)) }
        }
    }

    private func choose(_ choice: SlashChoice) {
        guard case .bot(let bot, _) = choice else { return }
        let handle = chat.room.members.first { $0.profile == bot.name }?.handle ?? bot.mentionTag
        field.insert(MessageReference(kind: .bot, value: handle))
        selection = nil
    }

    private func handleKey(_ key: ComposerKey) -> Bool {
        let choices = choices
        let current = choices.firstIndex { $0.id == selection } ?? 0
        switch key {
        case .send:
            if !choices.isEmpty {
                choose(choices[current])
                return true
            }
            guard sendWithReturn else { return false }
            if hasText { chat.send() }
            return true
        case .newline, .sendNext:
            return false
        case .redirect:
            // ⌘Return sends.
            if hasText { chat.send() }
            return true
        case .up, .down:
            guard !choices.isEmpty else { return false }
            selection = choices[min(max(0, current + (key == .up ? -1 : 1)), choices.count - 1)].id
            return true
        case .tab:
            guard !choices.isEmpty else { return false }
            choose(choices[current])
            return true
        case .escape:
            guard !choices.isEmpty, let query = field.query else { return false }
            dismissedQueryStart = query.range.location
            return true
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !choices.isEmpty {
                SlashMenu(
                    sections: [.init(title: String(localized: "Members"), choices: choices)],
                    selection: selection ?? choices.first?.id,
                    showsKeyHints: false,
                    onChoose: choose
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                PillTextView(
                    text: $chat.draft,
                    references: $chat.draftReferences,
                    command: .constant(nil),
                    isFocused: focused,
                    placeholder: String(localized: "Message \(chat.room.name)"),
                    controller: field,
                    context: context,
                    maxHeight: 200,
                    menuOpen: !choices.isEmpty,
                    sendWithReturn: sendWithReturn,
                    onKey: handleKey,
                    onPeek: { peek = $0 }
                )
                .padding(.vertical, 9)
                .popover(item: $peek, attachmentAnchor: .rect(.rect(peek?.rect ?? .zero))) { peek in
                    ReferencePreviewCard(item: peek.item, onRemove: {
                        if case .reference(let reference) = peek.item { field.remove(reference) }
                    }, onDismiss: { self.peek = nil })
                    .environment(\.references, context)
                    .presentationCompactAdaptation(.popover)
                }
                Button {
                    if hasText { chat.send() } else { chat.stop() }
                } label: {
                    Image(systemName: hasText || !chat.isWorking ? "arrow.up" : "stop.fill")
                        .font(.system(size: hasText || !chat.isWorking ? 16 : 12, weight: .bold))
                        .foregroundStyle(Theme.inkForeground)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.ink))
                        .opacity(hasText || chat.isWorking ? 1 : 0.35)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .disabled(!hasText && !chat.isWorking)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(hasText || !chat.isWorking ? "Send" : "Stop")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
        }
        .animation(Theme.snappy, value: choices.isEmpty)
        .onChange(of: field.query) { _, query in
            selection = nil
            if query?.range.location != dismissedQueryStart { dismissedQueryStart = nil }
        }
        .onChange(of: choices.isEmpty, initial: true) { _, isEmpty in
            field.showsCapsule = !isEmpty
        }
    }
}

/// Activity (`groupActivity`): the round, and where each Bot is in it.
private struct GroupActivityView: View {
    let chat: GroupChatModel
    let workspace: BotWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let active = chat.room.members.firstIndex { $0.memberID == chat.activeMemberID }
                    ForEach(Array(chat.room.members.enumerated()), id: \.element.id) { index, member in
                        let bot = workspace.roster?.bot(named: member.profile)
                        MemberStatusRow(
                            appearance: bot.flatMap { workspace.roster?.appearance(for: $0) },
                            name: bot?.title ?? member.displayName ?? member.handle,
                            subtitle: (chat.room.members.first == member ? String(localized: "Lead · ") : "") + "@\(member.handle)",
                            status: status(for: member),
                            // Everyone looks at the member that's replying.
                            look: active.flatMap { $0 == index || chat.memberStates[member.memberID] == .passed ? nil : CGVector(dx: 0.2, dy: $0 > index ? 1 : -1) }
                        )
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Round \(chat.currentRound) of \(RoomTranscript.maxRounds)")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                            .textCase(nil)
                        Text("Each Bot replies only when it has something new to add. Stop pauses the room.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .textCase(nil)
                    }
                    .padding(.bottom, 6)
                }
            }
            .navigationTitle("Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 420)
        #endif
    }

    private func status(for member: GroupRoom.Member) -> MemberStatusRow.Status {
        switch chat.memberStates[member.memberID] {
        case .replied?: .replied
        case .passed?: .passed
        case .failed?: .paused
        case .waiting?, nil:
            // The log names whose turn is running; older gateways don't, so all waiting ones reply.
            if let active = chat.activeMemberID { active == member.memberID ? .replying : .waiting } else { chat.isWorking ? .replying : .waiting }
        }
    }
}

/// New Group Chat (`newGroup`, `macNewGroup`): a name and two to six Bots.
struct NewGroupSheet: View {
    let roster: BotRoster
    let onDone: (GroupRoom?) -> Void

    @State private var name = ""
    @State private var picked: [String] = []
    @State private var isCreating = false
    @State private var error: String?

    private var bots: [BotProfile] { roster.visibleBots + roster.hiddenBots }
    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (2...6).contains(picked.count) && !isCreating }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let faces = picked.prefix(2).compactMap { roster.bot(named: $0).map(roster.appearance(for:)) }
                    GroupAvatar(front: faces.last, back: faces.count > 1 ? faces.first : nil, size: 72, cutout: Theme.groupedBackground)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text("Launch crew"))
                        .labelsHidden()
                }
                Section {
                    ForEach(bots) { bot in
                        MemberPickRow(
                            appearance: roster.appearance(for: bot),
                            name: bot.title,
                            handle: bot.mentionTag,
                            role: bot.role,
                            isOn: picked.contains(bot.name)
                        ) {
                            if let index = picked.firstIndex(of: bot.name) {
                                picked.remove(at: index)
                            } else if picked.count < 6 {
                                picked.append(bot.name)
                            }
                        }
                    }
                } header: {
                    Text("Members · \(picked.count) of \(bots.count)")
                } footer: {
                    Text("Pick 2 to 6 Bots. Each one replies only when it has something new to add. The first one you pick leads.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Group Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create", action: create).disabled(!canCreate)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480).frame(minHeight: 480, idealHeight: 600)
        #endif
    }

    private func create() {
        let members = picked.compactMap(roster.bot(named:))
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let room = try await roster.groupRooms.create(name: name.trimmingCharacters(in: .whitespaces), bots: members)
                onDone(room)
            } catch {
                self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// Group Settings (`groupSettings`, `macGroupSettings`): name, members, Delete Group.
private struct GroupSettingsSheet: View {
    let chat: GroupChatModel
    let rooms: GroupRooms
    let workspace: BotWorkspace
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MemberStack(appearances: chat.room.members.compactMap { member in workspace.roster?.bot(named: member.profile).flatMap { workspace.roster?.appearance(for: $0) } }, size: 40)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name", text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Renaming keeps the whole history.")
                }
                Section {
                    ForEach(chat.room.members) { member in
                        let bot = workspace.roster?.bot(named: member.profile)
                        HStack(spacing: 10) {
                            if let bot, let roster = workspace.roster {
                                BotFace(appearance: roster.appearance(for: bot), size: 26)
                            }
                            Text(bot?.title ?? member.displayName ?? member.handle)
                            if chat.room.members.first == member {
                                TagLabel(title: String(localized: "Lead"))
                            } else {
                                Text("@\(member.handle)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                } header: {
                    Text("Members · \(chat.room.members.count)")
                } footer: {
                    Text("Hermes fixes a room's members when it's created. To change them, start a new group chat.")
                }
                Section {
                    Button("Delete Group", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Deleting removes the room and its history for every member.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Group Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                }
            }
            .alert("Delete “\(chat.room.name)”?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await rooms.disband(chat.room)
                            workspace.selection = nil
                            dismiss()
                        } catch {
                            self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
                        }
                    }
                }
            } message: {
                Text("The room and its history are removed for every member.")
            }
        }
        .onAppear { name = chat.room.name }
        #if os(macOS)
        .frame(width: 440).frame(minHeight: 460, idealHeight: 560)
        #endif
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != chat.room.name else {
            dismiss()
            return
        }
        Task {
            do {
                try await rooms.rename(chat.room, to: trimmed)
                dismiss()
            } catch {
                self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
            }
        }
    }
}
