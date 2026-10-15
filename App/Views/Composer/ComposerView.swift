import HermesKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer (`blocks/composer.elyx`, `docs/composer.md`): one floating Liquid Glass panel.
/// Top to bottom, each row only when it has content: the queue, images, the text, then + · Think
/// (the send mode while a turn runs and there's something to send) · Dictate and one tinted
/// button (Voice mode when empty, Send with content, Stop while a turn runs).
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    var focused: Binding<Bool>
    /// Opens Voice mode; `nil` where it isn't available.
    var onVoiceMode: (() -> Void)?

    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var showsCamera = false
    @State private var dictation = DictationController()
    /// What the field held when dictation started; Cancel puts it back.
    @State private var draftBeforeDictation = ""
    @State private var showsMicrophoneDenied = false
    @State private var attachError: String?
    @State private var slashSelection: SlashChoice.ID?
    /// Escape turned the query starting here back into plain text.
    @State private var dismissedQueryStart: Int?
    @State private var showsAllSkills = false
    @State private var pathItems: [PathCompletion] = []
    @State private var field = PillTextController()
    @State private var peek: PillPeek?
    @State private var skillPeek: String?

    private var roster: BotRoster? {
        conversation.isBotChat ? workspace.roster : nil
    }

    private var isOffline: Bool {
        if let roster { return !roster.isConnected }
        if case .failed = workspace.connection { return true }
        return false
    }

    private var placeholder: String {
        if isOffline { return String(localized: "Offline") }
        if let target = conversation.helperSteerTarget { return String(localized: "Note for helper \(target.number)") }
        if let roster, let name = conversation.botName {
            let title = roster.bot(named: name)?.title ?? name
            return String(localized: "Message \(title)")
        }
        if conversation.isEmpty, conversation.sessionID == nil, !conversation.isBotChat,
           let id = (conversation.placement ?? workspace.projects.defaultPlacement).projectID,
           let name = workspace.projects.project(id)?.name {
            return String(localized: "Ask about \(name)")
        }
        return conversation.isEmpty ? String(localized: "Ask Hermes anything") : String(localized: "Reply to Hermes")
    }

    private var hint: String? {
        if let roster {
            switch roster.state {
            case .online: return nil
            case .connecting, .idle: return String(localized: "Connecting…")
            case .signInRequired: return String(localized: "Sign-in needed")
            case .failed: return nil
            }
        }
        if case .connecting = workspace.connection { return String(localized: "Connecting…") }
        return nil
    }

    var body: some View {
        VStack(spacing: 8) {
            if !slashSections.isEmpty {
                SlashMenu(
                    sections: slashSections,
                    selection: slashSelection ?? slashChoices.first?.id,
                    showsKeyHints: showsKeyHints,
                    hiddenSkillCount: hiddenSkillCount,
                    onChoose: choose,
                    onShowAllSkills: { showsAllSkills = true }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)).animation(Theme.snappy))
            }
            panel
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoSelection, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let attachment = await ImageAttachment.make(from: data) {
                        conversation.attachments.append(attachment)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await attachFiles(urls) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                Task {
                    if let attachment = await ImageAttachment.make(from: data) {
                        conversation.attachments.append(attachment)
                    }
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .onChange(of: dictation.transcript) { _, words in
            guard dictation.isActive else { return }
            conversation.draft = joined(draftBeforeDictation, words)
        }
        .onChange(of: dictation.state) { _, state in
            if state == .denied { showsMicrophoneDenied = true }
        }
        .alert("Can't Attach", isPresented: Binding(get: { attachError != nil }, set: { if !$0 { attachError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachError ?? "")
        }
        .alert("Microphone is off for Hermes", isPresented: $showsMicrophoneDenied) {
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            #endif
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on the microphone and speech recognition for Hermes in Settings to dictate. You can keep typing.")
        }
        // The composer changes height in one step and what comes into it fades in (an eased
        // height would slide the field under a row still fading in); the chat above eases to
        // its new end.
        .task(id: conversation.usesGateway) { conversation.loadSlashCatalog() }
        .task(id: pathToken) {
            guard let token = pathToken else {
                pathItems = []
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            pathItems = await conversation.completePath(token)
        }
        .onChange(of: conversation.editing?.id) { _, id in
            if id != nil { focused.wrappedValue = true }
        }
        .onChange(of: conversation.editingQueued?.original.id) { _, id in
            if id != nil { focused.wrappedValue = true }
        }
        .onChange(of: conversation.draft) { peek = nil }
        .onChange(of: conversation.id) {
            // Another chat in the same composer: the last one's menus, previews and dictation go.
            if dictation.isActive { dictation.cancel() }
            draftBeforeDictation = ""
            slashSelection = nil
            dismissedQueryStart = nil
            showsAllSkills = false
            pathItems = []
            peek = nil
            skillPeek = nil
            attachError = nil
            photoSelection = []
        }
        .onChange(of: field.query) { _, query in
            slashSelection = nil
            if query?.range.location != dismissedQueryStart { dismissedQueryStart = nil }
            if query?.trigger != "/" { showsAllSkills = false }
        }
        .onChange(of: slashSections.isEmpty, initial: true) { _, isEmpty in
            field.showsCapsule = !isEmpty && activeQuery != nil
        }
        .onChange(of: activeQuery) { _, query in
            field.showsCapsule = !slashSections.isEmpty && query != nil
        }
    }

    /// The pills' Bots, skills and files.
    private var referenceContext: ReferenceContext {
        ReferenceContext(workspace: workspace, catalog: conversation.slashCatalog)
    }


    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !conversation.queue.isEmpty || !conversation.gatewayQueued.isEmpty {
                QueueTray(conversation: conversation)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .transition(Self.rowAppears)
            }
            if let editing = conversation.editingQueued {
                ComposerStrip(
                    symbol: "pencil",
                    text: String(localized: "Editing queued message \(conversation.gatewayQueued.count + editing.index + 1) · Send puts it back"),
                    closeLabel: "Stop editing",
                    onClose: { conversation.cancelEditingQueued() }
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .transition(Self.rowAppears)
            }
            if let target = conversation.helperSteerTarget {
                // Steering one helper (`helperSteer`): Send goes to it, not to Hermes.
                ComposerStrip(
                    symbol: "arrow.turn.up.right",
                    text: String(localized: "To helper \(target.number) · it reads this after its current step"),
                    closeLabel: "Stop steering",
                    onClose: { conversation.helperSteerTarget = nil }
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .transition(Self.rowAppears)
            }
            if conversation.editing != nil {
                ComposerStrip(symbol: "pencil", text: String(localized: "Editing · sends as a new branch"), closeLabel: "Stop editing") {
                    conversation.cancelEditing()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .transition(Self.rowAppears)
            }
            if !conversation.attachments.isEmpty {
                AttachmentStrip(attachments: $conversation.attachments)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .transition(Self.rowAppears)
            }
            if !conversation.skills.isEmpty {
                // The tray (`composerSkills`): skills apply to the whole message, up to five.
                FlowLayout(spacing: 6) {
                    ForEach(conversation.skills, id: \.self) { skill in
                        skillChip(skill)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .transition(Self.rowAppears)
            }
            if !conversation.files.isEmpty {
                FileChips(files: $conversation.files)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .transition(Self.rowAppears)
            }
            PillTextView(
                text: $conversation.draft,
                references: $conversation.draftReferences,
                command: $conversation.draftCommand,
                isFocused: focused,
                placeholder: placeholder,
                controller: field,
                context: referenceContext,
                maxHeight: 260,
                menuOpen: !slashSections.isEmpty,
                sendWithReturn: sendWithReturn,
                onKey: handleKey,
                onPeek: { peek = $0 },
                onPasteImages: pasteImages,
                onPasteFiles: { urls in Task { await attachFiles(urls) } }
            )
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, conversation.draftCommand == nil ? 8 : 4)
            .popover(item: $peek, attachmentAnchor: .rect(.rect(peek?.rect ?? .zero))) { peek in
                ReferencePreviewCard(item: peek.item, onRemove: {
                    if case .reference(let reference) = peek.item { field.remove(reference) }
                }, onDismiss: { self.peek = nil })
                .environment(\.references, referenceContext)
                .presentationCompactAdaptation(.popover)
            }

            if let command = conversation.draftCommand {
                // One line under the field while a command waits for its argument.
                Text(CommandMode.hint(SlashCommands.info(command)))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            Group {
                if dictation.isActive {
                    DictationRow(dictation: dictation, onCancel: cancelDictation, onDone: finishDictation)
                        .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
                } else {
                    controls
                        .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous))
        .onTapGesture { focused.wrappedValue = true }
    }

    /// While a turn runs and there's something to send, the send mode takes Think's place: Think
    /// applies to the next turn anyway.
    private var showsModeChip: Bool {
        (conversation.canSendFollowUp || conversation.editingQueued != nil) && !dictation.isActive
    }

    /// A row coming into the composer or the bar (the queue, a strip, attachments, a card): it
    /// fades in as its room opens.
    static let rowAppears = AnyTransition.opacity.animation(.easeOut(duration: 0.22))


    private var controls: some View {
        HStack(spacing: 6) {
            attachMenu
            // Think and the send mode share one place and cross-fade. Neither comes or goes, so
            // no leaving copy can linger where the chip was while the composer changes height.
            ZStack(alignment: .leading) {
                if !conversation.isBotChat {
                    EffortMenu(conversation: conversation, workspace: workspace)
                        .modifier(ChipSlot(isShown: !showsModeChip))
                }
                FollowUpModeChip(conversation: conversation, focused: focused)
                    .modifier(ChipSlot(isShown: showsModeChip))
            }
            // Where the chat runs (projects). It stays in place under the send mode, faded.
            ProjectChip(conversation: conversation, workspace: workspace)
                .opacity(showsModeChip ? 0 : 1)
                .allowsHitTesting(!showsModeChip)
                .animation(.easeOut(duration: 0.18), value: showsModeChip)
            Spacer(minLength: 4)
            if let status = hint {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Button {
                startDictation()
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(isOffline)
            .accessibilityLabel("Dictate")
            .help("Dictate")
            TrailingButton(conversation: conversation, isOffline: isOffline, onVoiceMode: onVoiceMode)
        }
        .opacity(isOffline ? 0.5 : 1)
    }

    // MARK: Slash menu

    private var showsKeyHints: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    /// The token being typed after `/` or `@`, unless Escape turned it back into text.
    private var activeQuery: ComposerQuery? {
        guard !dictation.isActive, let query = field.query, query.range.location != dismissedQueryStart else { return nil }
        return query
    }

    private var slashQuery: SlashQuery? {
        guard !dictation.isActive else { return nil }
        if let command = conversation.draftCommand {
            // `/model`'s values while it waits for its argument (`slashMenuArgs`).
            let info = SlashCommands.info(command)
            return info.takesOptions ? .values(command: info.name, query: conversation.draft.trimmingCharacters(in: .whitespaces)) : nil
        }
        guard let query = activeQuery, query.trigger == "/" else { return nil }
        return .names(query.text)
    }

    /// Commands only start an otherwise empty message: none with skills, pills or other text.
    private var offersCommands: Bool {
        guard let query = field.query else { return false }
        return conversation.skills.isEmpty && conversation.draftReferences.isEmpty && conversation.attachments.isEmpty && conversation.files.isEmpty
            && conversation.draft.utf16.count == query.range.length
    }

    private var hiddenSkillCount: Int {
        guard case .names("")? = slashQuery, !showsAllSkills, let catalog = conversation.slashCatalog else { return 0 }
        return max(0, catalog.skills.count - 3)
    }

    /// The `@word` being typed, for gateway path completion (`complete.path`).
    private var pathToken: String? {
        guard conversation.usesGateway, let query = activeQuery, query.trigger == "@" else { return nil }
        return "@" + query.text
    }

    /// Bots matching the `@word` (`composerMention`).
    private var mentionedBots: [BotProfile] {
        guard let roster = workspace.roster, let query = activeQuery, query.trigger == "@" else { return [] }
        return MentionSuggestions.matches(query.text.lowercased(), roster: roster, excluding: conversation.botName)
    }

    private var slashSections: [SlashMenu.Section] {
        if slashQuery == nil, let query = activeQuery, query.trigger == "@" {
            var sections: [SlashMenu.Section] = []
            if let roster = workspace.roster {
                let bots = mentionedBots
                if !bots.isEmpty {
                    sections.append(.init(title: String(localized: "Bots"), choices: bots.map { .bot($0, roster.appearance(for: $0)) }))
                }
            }
            let handles = Set(mentionedBots.flatMap { ReferenceContext.handles(of: $0) })
            // Profiles come back from `complete.path` too; the Bots section already has them.
            let paths = pathItems.filter { !($0.text.hasPrefix("@") && !$0.text.contains(":") && handles.contains(String($0.text.dropFirst()).lowercased())) }
            if !paths.isEmpty {
                sections.append(.init(title: String(localized: "Files on \(workspace.bot.name)"), choices: paths.map { .path($0) }))
            }
            return sections
        }
        guard let query = slashQuery, let catalog = conversation.slashCatalog else { return [] }
        switch query {
        case .values(let command, let text):
            let values = catalog.values(for: command, workspace: workspace, conversation: conversation, query: text)
            guard !values.isEmpty else { return [] }
            let title = command == "model" ? String(localized: "/model · choose a model") : String(localized: "/\(command) · choose a level")
            return [SlashMenu.Section(title: title, choices: values.map { .value(command: command, $0) })]
        case .names(let text):
            var found = catalog.matches(text, includeSkills: conversation.usesGateway && conversation.skills.count < MessageParts.maxSkills)
            if !offersCommands { found.commands = [] }
            if text.isEmpty {
                var sections: [SlashMenu.Section] = []
                if !found.skills.isEmpty {
                    let shown = showsAllSkills ? found.skills : Array(found.skills.prefix(3))
                    sections.append(.init(title: String(localized: "Skills · \(found.skills.count)"), choices: shown.map { .entry($0) }))
                }
                for group in SlashCommandInfo.Group.allCases {
                    let commands = found.commands.filter { $0.group == group }
                    if !commands.isEmpty {
                        sections.append(.init(title: String(localized: String.LocalizationValue(group.title)), choices: commands.map { .entry($0) }))
                    }
                }
                return sections
            }
            let all = (found.skills + found.commands).prefix(12).map { SlashChoice.entry($0) }
            return all.isEmpty ? [] : [.init(title: String(localized: "Matches for “/\(text)”"), choices: Array(all))]
        }
    }

    private var slashChoices: [SlashChoice] {
        slashSections.flatMap(\.choices)
    }

    private var selectedSlashChoice: SlashChoice? {
        let choices = slashChoices
        guard !choices.isEmpty else { return nil }
        return choices.first { $0.id == slashSelection } ?? choices.first
    }

    private func moveSlashSelection(_ step: Int) -> KeyPress.Result {
        let choices = slashChoices
        guard !choices.isEmpty else { return .ignored }
        let current = choices.firstIndex { $0.id == slashSelection } ?? 0
        let next = min(max(0, current + step), choices.count - 1)
        slashSelection = choices[next].id
        return .handled
    }

    /// Tab: a command waits for its argument; a command without one is completed, not run;
    /// anything else is chosen.
    private func completeSlashSelection() -> KeyPress.Result {
        guard let choice = selectedSlashChoice else { return .ignored }
        switch choice {
        case .entry(let entry) where entry.kind == .command:
            let info = entry.info ?? SlashCommands.info(entry.name)
            if CommandMode.takesArgument(info) {
                choose(choice)
            } else {
                field.replaceQuery(with: "/\(entry.name)")
            }
        default:
            choose(choice)
        }
        return .handled
    }

    private func choose(_ choice: SlashChoice) {
        switch choice {
        case .entry(let entry) where entry.kind == .skill:
            // The skill goes to the tray; its "/name" leaves the field.
            if !conversation.skills.contains(entry.name), conversation.skills.count < MessageParts.maxSkills {
                conversation.skills.append(entry.name)
            }
            field.replaceQuery(with: "")
            focused.wrappedValue = true
        case .entry(let entry):
            let info = entry.info ?? SlashCommands.info(entry.name)
            if CommandMode.takesArgument(info) {
                // Command mode (`composerCommand`): the pill starts the field.
                conversation.draftReferences = []
                conversation.draft = ""
                conversation.draftCommand = info.name
                focused.wrappedValue = true
            } else {
                conversation.runCommand(entry.name, argument: nil)
            }
        case .value(let command, let value):
            conversation.runCommand(command, argument: value.value)
        case .path(let item):
            if !item.isFolder, let reference = MessageReference(plainText: item.text) {
                field.insert(reference)
            } else {
                // A folder stays open for the next part of the path; `@diff` and the like are text.
                field.replaceQuery(with: item.text + (item.isFolder || item.text.hasSuffix(":") ? "" : " "))
            }
            focused.wrappedValue = true
        case .bot(let bot, _):
            field.insert(MessageReference(kind: .bot, value: bot.mentionTag))
            focused.wrappedValue = true
        }
        slashSelection = nil
    }

    /// A skill in the tray: long-press (hover on the Mac) previews it with Remove and Show Skill.
    private func skillChip(_ skill: String) -> some View {
        SkillChip(name: skill) { conversation.skills.removeAll { $0 == skill } }
            .onLongPressGesture(minimumDuration: 0.35) { skillPeek = skill }
            #if os(macOS)
            .onHover { inside in if inside { skillPeek = skill } }
            #endif
            .popover(isPresented: Binding(get: { skillPeek == skill }, set: { if !$0 { skillPeek = nil } })) {
                ReferencePreviewCard(item: .skill(skill), onRemove: { conversation.skills.removeAll { $0 == skill } }, onDismiss: { skillPeek = nil })
                    .environment(\.references, referenceContext)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func pasteImages(_ images: [PlatformImage]) {
        guard conversation.supportsImages else { return }
        Task {
            for image in images {
                // Encoded off the main thread: a full-size photo took a noticeable moment.
                #if os(iOS)
                guard let data = await Task.detached(priority: .userInitiated, operation: { image.pngData() }).value else { continue }
                #else
                guard let data = image.tiffRepresentation else { continue }
                #endif
                if let attachment = await ImageAttachment.make(from: data) {
                    conversation.attachments.append(attachment)
                }
            }
        }
    }

    // MARK: Files

    /// Images become image attachments; anything else goes as a file. The API server can only
    /// take files it can read as text.
    private func attachFiles(_ urls: [URL]) async {
        var problems: [String] = []
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, conversation.supportsImages {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                if let data, let attachment = await ImageAttachment.make(from: data) {
                    conversation.attachments.append(attachment)
                    continue
                }
            }
            do {
                let file = try await Task.detached { try FileAttachment.load(url) }.value
                if !conversation.usesGateway, file.inlineText == nil {
                    problems.append(String(localized: "“\(file.name)” isn't text, and this chat can only send text files and PDFs. Turn on Bot Mode to send any file."))
                    continue
                }
                conversation.files.append(file)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty { attachError = problems.joined(separator: "\n") }
    }

    // MARK: Dictation

    private func startDictation() {
        draftBeforeDictation = conversation.draft
        focused.wrappedValue = false
        Task { await dictation.start() }
    }

    private func finishDictation() {
        Task {
            let words = await dictation.finish()
            conversation.draft = joined(draftBeforeDictation, words)
            focused.wrappedValue = true
        }
    }

    private func cancelDictation() {
        dictation.cancel()
        conversation.draft = draftBeforeDictation
    }

    private func joined(_ base: String, _ words: String) -> String {
        guard !words.isEmpty else { return base }
        guard !base.isEmpty else { return words }
        return base.hasSuffix(" ") || base.hasSuffix("\n") ? base + words : base + " " + words
    }

    /// Keys the field passes up: Return chooses from an open menu or sends (hardware keyboards
    /// only; the on-screen return inserts a newline), arrows and Tab work the menu, Escape
    /// closes it or leaves command mode.
    private func handleKey(_ key: ComposerKey) -> Bool {
        switch key {
        case .send:
            if let choice = selectedSlashChoice {
                choose(choice)
                return true
            }
            guard sendWithReturn else { return false }
            if conversation.canSteerHelper || conversation.canSend || conversation.canSendFollowUp || conversation.editingQueued != nil {
                conversation.send()
            }
            return true
        case .newline:
            return false
        case .sendNext:
            // ⌥Return: Send Next while a turn runs; otherwise a new line.
            guard conversation.canSendFollowUp, conversation.availableFollowUpModes.contains(.sendNext) else { return false }
            conversation.sendFollowUp(.sendNext)
            return true
        case .redirect:
            // ⌘Return: Redirect while a turn runs (where the gateway can); otherwise Send.
            if conversation.canSendFollowUp, sendWithReturn, conversation.availableFollowUpModes.contains(.redirect) {
                conversation.sendFollowUp(.redirect)
            } else if conversation.canSteerHelper || conversation.canSend || conversation.canSendFollowUp || conversation.editingQueued != nil {
                conversation.send()
            }
            return true
        case .up:
            return moveSlashSelection(-1) == .handled
        case .down:
            return moveSlashSelection(1) == .handled
        case .tab:
            return completeSlashSelection() == .handled
        case .escape:
            if !slashSections.isEmpty, let query = field.query {
                dismissedQueryStart = query.range.location
                field.showsCapsule = false
                return true
            }
            if conversation.draftCommand != nil, conversation.draft.isEmpty {
                conversation.draftCommand = nil
                return true
            }
            return false
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                .disabled(!conversation.supportsImages)
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { showsCamera = true }
                    .disabled(!conversation.supportsImages)
            }
            #endif
            Button("Files", systemImage: "folder") { showsFileImporter = true }
                .disabled(isOffline)
            if !conversation.isBotChat, conversation.usesGateway {
                Button("File on Gateway…", systemImage: "externaldrive.connected.to.line.below") {
                    let draft = conversation.draft
                    conversation.draft = draft.isEmpty || draft.hasSuffix(" ") ? draft + "@" : draft + " @"
                    focused.wrappedValue = true
                }
            }
            if conversation.usesGateway, conversation.slashCatalog?.skills.isEmpty == false {
                Divider()
                Button("Skills…", systemImage: "book.closed") {
                    showsAllSkills = true
                    conversation.draft = "/"
                    focused.wrappedValue = true
                }
                Button("Commands…", systemImage: "slash.circle") {
                    conversation.draft = "/"
                    focused.wrappedValue = true
                }
                Divider()
            }
            Button("Paste", systemImage: "doc.on.clipboard") {
                guard let data = Pasteboard.imageData() else { return }
                Task {
                    if let attachment = await ImageAttachment.make(from: data) {
                        conversation.attachments.append(attachment)
                    }
                }
            }
            .disabled(!Pasteboard.hasImage || !conversation.supportsImages)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 36, height: 36)
                .overlay { Circle().strokeBorder(Theme.hairline) }
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isOffline)
        .help("Attach")
        .accessibilityLabel("Attach")
    }
}

/// One of the chips that share a place: shown, or faded out and out of reach.
private struct ChipSlot: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .animation(.smooth(duration: 0.2)) {
                $0.opacity(isShown ? 1 : 0).scaleEffect(isShown ? 1 : 0.94, anchor: .leading)
            }
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

// MARK: - Trailing button

/// The one tinted control: Voice mode when there's nothing to send, Send with content (or a
/// follow-up while a turn runs), Stop while a turn runs and the field is empty.
private struct TrailingButton: View {
    let conversation: ConversationModel
    let isOffline: Bool
    var onVoiceMode: (() -> Void)?

    private enum Mode { case voice, send, stop }

    private var mode: Mode {
        if conversation.helperSteerTarget != nil { return .send }
        if conversation.isWorking {
            let hasContent = conversation.hasDraftText || !conversation.attachments.isEmpty || !conversation.files.isEmpty
            return hasContent || conversation.draftCommand != nil || conversation.editingQueued != nil ? .send : .stop
        }
        if conversation.hasDraftText || !conversation.attachments.isEmpty || !conversation.skills.isEmpty || conversation.draftCommand != nil || onVoiceMode == nil { return .send }
        // Stopped with messages waiting: Send sends the first.
        if conversation.canSendQueued || conversation.editingQueued != nil { return .send }
        return .voice
    }

    private var symbol: String {
        switch mode {
        case .stop: "stop.fill"
        case .send: "arrow.up"
        case .voice: "waveform"
        }
    }

    private var symbolSize: CGFloat {
        switch mode {
        case .stop: 12
        case .send: 16
        case .voice: 15
        }
    }

    private var isEnabled: Bool {
        guard !isOffline else { return false }
        switch mode {
        case .stop: return !conversation.isStopping
        case .send:
            if conversation.helperSteerTarget != nil { return conversation.hasDraftText }
            // A command waits for its argument before Send turns on (`composerCommand`).
            if conversation.draftCommand != nil { return conversation.canSendCommand }
            if conversation.editingQueued != nil { return true }
            return conversation.isWorking ? conversation.canSendFollowUp : conversation.canSend || conversation.canSendQueued
        case .voice: return true
        }
    }

    /// What Send does while a turn runs: "Send, Steer".
    private var sendLabel: LocalizedStringKey {
        "Send, \(conversation.followUpMode.title)"
    }

    var body: some View {
        Button {
            switch mode {
            case .stop: conversation.stop()
            case .send: conversation.send()
            case .voice: onVoiceMode?()
            }
        } label: {
            // Only the glyph and its tone animate: the button itself never eases from where it
            // was, which inside a composer that just grew would float it out of place.
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .animation(Theme.snappy, value: mode)
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.ink))
                .animation(Theme.snappy) { $0.opacity(isEnabled || isOffline ? 1 : 0.35) }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        // While a turn runs ⌘Return redirects; the field handles it.
        .keyboardShortcut(mode == .send && !conversation.isWorking ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .accessibilityLabel(mode == .stop ? "Stop" : mode == .send ? (conversation.helperSteerTarget != nil ? "Send to helper" : conversation.isWorking ? sendLabel : "Send") : "Voice mode")
        .help(mode == .stop ? "Stop (⌘.)" : mode == .send ? "Send (⌘↩)" : "Voice mode")
    }
}

// MARK: - Dictation row

/// While dictating, the controls row becomes Cancel, a live level meter, the elapsed time and Done.
private struct DictationRow: View {
    let dictation: DictationController
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Cancel dictation")
            if dictation.state == .preparing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else {
                LevelMeter(levels: dictation.levels)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .accessibilityLabel("Listening")
            }
            if let started = dictation.startedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 36, height: 36)
                    .background(Theme.ink, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(dictation.state != .listening)
            .accessibilityLabel("Done")
        }
    }
}

/// Bars that follow the microphone level, newest on the right.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(index >= levels.count - 7 ? Theme.tertiaryText : Theme.primaryText)
                    .frame(width: 3, height: max(4, CGFloat(level) * 24))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

// MARK: - Files

/// File and PDF chips (`composerFiles`): the name with a remove button.
private struct FileChips: View {
    @Binding var files: [FileAttachment]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files) { file in
                HStack(spacing: 5) {
                    Image(systemName: file.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(file.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        files.removeAll { $0.id == file.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(file.name)")
                }
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .frame(height: 26)
                .frame(maxWidth: 220)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
            }
        }
    }
}

// MARK: - Reasoning effort

private struct EffortMenu: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace

    private static let levels: [ReasoningEffort] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]

    var body: some View {
        Menu {
            Picker("Reasoning", selection: $conversation.reasoningEffort) {
                Text("Auto").tag(nil as ReasoningEffort?)
                Divider()
                ForEach(Self.levels) { level in
                    Text(Self.title(for: level)).tag(Optional(level))
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(
                title: conversation.reasoningEffort.map { String(localized: "Think: \(Self.title(for: $0))") } ?? String(localized: "Think"),
                symbol: conversation.reasoningEffort == nil ? "lightbulb" : "lightbulb.fill",
                isActive: conversation.reasoningEffort != nil
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reasoning effort")
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(conversation.reasoningEffort.map(Self.title(for:)) ?? String(localized: "Auto"))
    }

    static func title(for level: ReasoningEffort) -> String {
        switch level {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Max")
        }
    }
}

// MARK: - Attachments

struct AttachmentStrip: View {
    @Binding var attachments: [ImageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    Image(platformImage: attachment.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("Attached image \(index + 1) of \(attachments.count)")
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(Theme.spring) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.7), in: Circle())
                                    .padding(4)
                                    // A 40pt target in the corner; the badge stays small.
                                    .frame(width: 40, height: 40, alignment: .topTrailing)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove image \(index + 1)")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

/// Loads dropped or pasted images from item providers.
nonisolated enum AttachmentLoader {
    static func load(_ providers: [NSItemProvider], add: @escaping @MainActor @Sendable (ImageAttachment) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let attachment = await ImageAttachment.make(from: data) { add(attachment) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                          let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in
                        if let attachment = await ImageAttachment.make(from: data) { add(attachment) }
                    }
                }
            }
        }
    }
}

#if os(iOS)
/// The system camera, for snapping a photo to send.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                let onCapture = parent.onCapture
                Task { @MainActor in
                    // Encoded off the main thread, so the camera's dismissal doesn't hitch.
                    let data = await Task.detached(priority: .userInitiated) { image.jpegData(compressionQuality: 0.9) }.value
                    if let data { onCapture(data) }
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
