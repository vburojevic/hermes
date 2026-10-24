import AVFoundation
import HermesKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer (`blocks/composer.elyx`, `docs/composer.md`): one floating Liquid Glass panel.
/// Top to bottom, each row only when it has content: the queue, images, the text, then + · Think
/// (the send mode while a turn runs and there's something to send) · Dictate and one tinted
/// button (Talk when empty, Send with content, Stop while a turn runs).
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    var focused: Binding<Bool>
    /// Starts Talk (`docs/voice.md` §4); `nil` where it isn't available.
    var onVoiceMode: (() -> Void)?

    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var showsCamera = false
    /// Camera access was turned off: the system camera would open black.
    @State private var showsCameraDenied = false
    @State private var dictation = DictationController()
    @State private var showsMicrophoneDenied = false
    /// Voice messages (`docs/voice.md` §2): the recorder, and the finger holding the microphone.
    @State private var recorder = VoiceRecorder()
    @State private var hold = HoldGesture()
    @State private var panelWidth: CGFloat = 360
    /// A press too short to be a message: "Hold to record" shows in the field for a moment.
    @State private var showsHoldHint = false
    @State private var recordingFailure: String?
    @State private var sentVoiceMessages = 0
    @State private var attachError: String?
    @State private var slashSelection: SlashChoice.ID?
    /// Escape turned the query starting here back into plain text.
    @State private var dismissedQueryStart: Int?
    @State private var showsAllSkills = false
    /// The panel's top, for the room the menu above it has (`ComposerMenuRoom`).
    @State private var composerTop = ComposerTop()
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

    /// The Mac answers but is too loaded to take the Bots yet (`BotRoster.isBusy`): not offline,
    /// as the sidebar says too.
    private var isWaitingOnBusyMac: Bool {
        isOffline && (roster?.isBusy == true || workspace.isBusy)
    }

    private var placeholder: String {
        if showsHoldHint { return String(localized: "Hold to record") }
        // Talk minimised in this chat: what's typed is a turn of the call (`talkMinimised`).
        if let call = TalkCenter.shared.session, call.conversation === conversation, !TalkCenter.shared.isExpanded {
            return String(localized: "Type into the call")
        }
        if isWaitingOnBusyMac { return String(localized: "\(workspace.bot.name) is busy") }
        if let target = conversation.helperSteerTarget { return String(localized: "Note for helper \(target.number)") }
        // Sending answers the question on show (`docs/quick-actions.md` §1).
        if conversation.typedAnswerRequest != nil { return String(localized: "Answer \(conversation.askerName)") }
        if let roster, let name = conversation.botName {
            let title = roster.bot(named: name)?.title ?? name
            return String(localized: "Message \(title)")
        }
        if conversation.isEmpty, conversation.sessionID == nil, !conversation.isBotChat,
           let id = (conversation.placement ?? workspace.projects.defaultPlacement).projectID,
           let name = workspace.projects.project(id)?.name {
            return String(localized: "Ask about \(name)")
        }
        // A chat being opened is a reply from the start, while its messages load.
        let isNew = conversation.isEmpty && conversation.sessionID == nil
        return isNew ? String(localized: "Ask Hermes anything") : String(localized: "Reply to Hermes")
    }

    private var hint: String? {
        // The gateway's Mac is overloaded: everything works, slowly. Not "Offline".
        let busy = workspace.isBusy ? String(localized: "Mac is busy…") : nil
        if let roster {
            switch roster.state {
            case .online: return busy
            // A busy Mac is in the placeholder already.
            case .connecting, .idle: return isWaitingOnBusyMac ? String(localized: "Connecting…") : busy ?? String(localized: "Connecting…")
            case .signInRequired: return String(localized: "Sign-in needed")
            // Offline is no reason not to write: what's sent waits for the Mac (`docs/chat.md` §4).
            case .failed: return String(localized: "Offline · messages wait for \(workspace.bot.name)")
            }
        }
        switch workspace.connection {
        case .connecting: return busy ?? String(localized: "Connecting…")
        case .failed: return String(localized: "Offline · messages wait for \(workspace.bot.name)")
        default: return busy
        }
    }

    var body: some View {
        // Matched once per update: it walks every skill and command.
        let sections = slashSections
        VStack(spacing: 8) {
            if !sections.isEmpty {
                SlashMenu(
                    sections: sections,
                    selection: slashSelection ?? sections.first?.choices.first?.id,
                    showsKeyHints: showsKeyHints,
                    hiddenSkillCount: hiddenSkillCount,
                    composerTop: composerTop,
                    onChoose: choose,
                    onShowAllSkills: { showsAllSkills = true }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)).animation(Theme.snappy))
            }
            panel
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { composerTop.update($0) }
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
        // The words land at the caret as they're heard, the newest lighter (`docs/voice.md` §5).
        .onChange(of: dictation.transcript) {
            guard dictation.isActive else { return }
            field.updateDictation(settled: dictation.finalized, volatile: dictation.volatile)
        }
        .onChange(of: dictation.state) { _, state in
            if state == .denied { showsMicrophoneDenied = true }
        }
        // The Bot's face listens while the person dictates (`docs/bot-faces.md` §5.1).
        .onChange(of: dictation.isActive) { _, active in conversation.isDictating = active }
        .alert("Can't Attach", isPresented: Binding(get: { attachError != nil }, set: { if !$0 { attachError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachError ?? "")
        }
        .alert("Can't Send the Voice Message", isPresented: Binding(get: { recordingFailure != nil }, set: { if !$0 { recordingFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recordingFailure ?? "")
        }
        .sensoryFeedback(.success, trigger: sentVoiceMessages)
        .onChange(of: recorder.phase) { _, phase in
            // Locked, in Review or gone: the finger no longer drives the recording.
            if phase != .preparing, phase != .holding { hold.reset() }
        }
        .onChange(of: recorder.failure) { _, failure in
            if let failure { recordingFailure = failure }
        }
        // `docs/setup.md` §4.15: the way to the setting on every platform.
        .alert("Microphone is off for Hermes", isPresented: $showsMicrophoneDenied) {
            Button("Open Settings") { DeviceSetup.openSettings(.microphone) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(DeviceSetup.settingsPath(for: .microphone)) Until then you can't dictate or send voice messages; you can keep typing.")
        }
        #if os(iOS)
        .alert("Camera is off for Hermes", isPresented: $showsCameraDenied) {
            Button("Open Settings") { DeviceSetup.openSettings(.camera) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(DeviceSetup.settingsPath(for: .camera)) You can still pick photos from your library.")
        }
        #endif
        // The composer changes height in one step and what comes into it fades in (an eased
        // height would slide the field under a row still fading in); the chat above eases to
        // its new end.
        // Until the catalog is in: asked again when the chat's connection comes up, and when the
        // menu opens (a first ask before the socket was there would otherwise be the only one).
        .task(id: CatalogTrigger(usesGateway: conversation.usesGateway, connected: (roster ?? workspace.roster)?.isConnected == true)) {
            conversation.loadSlashCatalog()
        }
        .onChange(of: sections.isEmpty) { _, closed in
            if !closed { conversation.loadSlashCatalog() }
        }
        // The voice-message transcriber, ready before the first hold if its model is here.
        .task { await VoiceRecorder.prewarm() }
        #if DEBUG
        // `-HERMES_TYPE <text>` types into the composer as a person would, `-HERMES_TYPE_AFTER
        // <seconds>` after it appears (8): the "/" and "@" menus with the keyboard up, no taps.
        .task {
            guard let text = UserDefaults.standard.string(forKey: "HERMES_TYPE"), !text.isEmpty else { return }
            // Once per launch: a composer rebuilt (rotating to the split layout) doesn't type it again.
            UserDefaults.standard.removeObject(forKey: "HERMES_TYPE")
            let delay = UserDefaults.standard.string(forKey: "HERMES_TYPE_AFTER").flatMap(Double.init) ?? 8
            try? await Task.sleep(for: .seconds(delay))
            field.typeForTesting(text)
        }
        #endif
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
        .onChange(of: conversation.replyingTo?.rowID) { _, id in
            if id != nil { focused.wrappedValue = true }
        }
        .onChange(of: conversation.draft) { peek = nil }
        .onChange(of: conversation.id) {
            // Another chat in the same composer: the last one's menus, previews and dictation go.
            if dictation.isActive { dictation.cancel() }
            if recorder.isActive { recorder.cancel() }
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
        .onChange(of: sections.isEmpty, initial: true) { _, isEmpty in
            field.showsCapsule = !isEmpty && activeQuery != nil
        }
        .onChange(of: activeQuery) { _, query in
            field.showsCapsule = !sections.isEmpty && query != nil
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
            if let target = conversation.replyingTo {
                // Reply with a quote (`replyBar`, `docs/inbox.md` §4).
                ReplyBar(author: target.author, quote: target.quote) { conversation.replyingTo = nil }
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
            if conversation.hasUndoneMessage {
                // After Undo (`composerEditing`): the undone turn's message, back to edit.
                ComposerStrip(symbol: "arrow.uturn.backward", text: String(localized: "Undone · your message is back to edit"), closeLabel: "Discard the message") {
                    conversation.dismissUndoneMessage()
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
            if recorder.phase == .locked {
                RecorderLockedPanel(recorder: recorder, onDelete: deleteRecording, onPause: pauseRecording, onSend: sendRecording)
                    .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
                    .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
            } else if recorder.phase == .review {
                RecorderReviewPanel(recorder: recorder, onDelete: deleteRecording, onResume: resumeRecording, onSend: sendRecording)
                    .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
                    .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
            } else {
                if isHoldingToRecord {
                    // Holding (`recorder`): the words as they're heard, where the text was.
                    RecorderWords(settled: recorder.settled, volatile: recorder.volatile, placeholder: String(localized: "Listening…"))
                        .lineLimit(2)
                        .padding(EdgeInsets(top: 14, leading: 26, bottom: 6, trailing: 26))
                        .transition(.opacity)
                } else {
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
                        onPasteFiles: { urls in await attachFiles(urls) }
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
                }
                // The controls stay put while the finger holds the microphone: it keeps its press.
                Group {
                    if dictation.isActive {
                        DictationRow(dictation: dictation, onCancel: cancelDictation, onDone: finishDictation, onLanguage: restartDictation)
                            .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
                    } else if let failure = dictation.failure {
                        DictationFailureRow(message: failure, onRetry: startDictation, onDismiss: dictation.dismissFailure)
                            .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
                    } else {
                        controls
                            .transition(.opacity.animation(reduceMotion ? nil : Theme.snappy))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous))
        .onTapGesture { if !recorder.isActive { focused.wrappedValue = true } }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { panelWidth = $0 }
    }

    /// The finger is on the microphone and a voice message is recording.
    private var isHoldingToRecord: Bool {
        hold.isHolding && (recorder.phase == .preparing || recorder.phase == .holding)
    }

    /// A Bot Chat has no Think, and neither has the answer composer (`composerAnswer`): Send
    /// answers the question, so there's no turn to think about.
    private var collapsesChipSlot: Bool { (conversation.isBotChat || answersQuestion) && !showsModeChip }

    /// Send answers the question on show, not a new message.
    private var answersQuestion: Bool {
        conversation.typedAnswerRequest != nil && conversation.editingQueued == nil
    }

    /// While a turn runs and there's something to send, the send mode takes Think's place: Think
    /// applies to the next turn anyway. Not while Send answers a question: there's no mode to pick.
    private var showsModeChip: Bool {
        (conversation.canSendFollowUp || conversation.editingQueued != nil) && !dictation.isActive
            && !answersQuestion
    }

    /// A row coming into the composer or the bar (the queue, a strip, attachments, a card): it
    /// fades in as its room opens.
    static let rowAppears = AnyTransition.opacity.animation(.easeOut(duration: 0.22))


    private var controls: some View {
        HStack(spacing: 6) {
            if isHoldingToRecord {
                RecorderHoldBar(recorder: recorder, hold: hold)
                    .transition(.opacity)
            } else {
                attachMenu
                // Think and the send mode share one place and cross-fade. Neither comes or goes, so
                // no leaving copy can linger where the chip was while the composer changes height.
                ZStack(alignment: .leading) {
                    if !conversation.isBotChat {
                        EffortMenu(conversation: conversation, workspace: workspace)
                            .modifier(ChipSlot(isShown: !showsModeChip && !answersQuestion))
                    }
                    FollowUpModeChip(conversation: conversation, focused: focused)
                        .modifier(ChipSlot(isShown: showsModeChip))
                        // The first time the person types while Hermes works (`SteerTip.typedWhileWorking`).
                        .hermesTip(SteerTip(), arrowEdge: .bottom)
                }
                // A Bot Chat and the answer composer have no Think: the slot takes no room until the
                // send mode shows in it, so what follows (the process chip) sits next to +.
                .frame(width: collapsesChipSlot ? 0 : nil, alignment: .leading)
                .padding(.trailing, collapsesChipSlot ? -6 : 0)
                .animation(.smooth(duration: 0.2), value: collapsesChipSlot)
                // What runs in the background (`processChip`): the first to shrink, so it never
                // pushes the buttons at the end.
                ProcessChipView(conversation: conversation)
                    .layoutPriority(-1)
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
            }
            // Tap to dictate (on the device: it works offline, `docs/voice.md` §5); hold to
            // record a voice message (§2).
            MicButton(
                recorder: recorder,
                hold: hold,
                cancelDistance: panelWidth / 2,
                onDictate: startDictation,
                onRecord: startRecording,
                onSend: sendRecording,
                onCancel: deleteRecording,
                onLock: { recorder.lock() }
            )
            TrailingButton(conversation: conversation, isOffline: isOffline, onVoiceMode: onVoiceMode)
                .opacity(isHoldingToRecord ? 0 : 1)
                .allowsHitTesting(!isHoldingToRecord)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3), value: conversation.processChip == .hidden)
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
        case .entry(let entry) where entry.unavailable != nil:
            // It says why on its row; nothing to run.
            return
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
        guard conversation.supportsImages else {
            attachError = String(localized: "This chat can't send pictures. Turn on Bot Mode to send them.")
            return
        }
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
        // Typing carries on while the words come in.
        field.beginDictation()
        dictation.contextualStrings = SpeechVocabulary.words(workspace: workspace, conversation: conversation)
        dictation.locale = TalkPreferences.language
        Task { await dictation.start() }
    }

    private func finishDictation() {
        Task {
            let words = await dictation.finish()
            field.endDictation(words)
            focused.wrappedValue = true
        }
    }

    /// Another language: what was heard stays, and listening starts again in the new one.
    private func restartDictation() {
        Task {
            let words = await dictation.finish()
            field.endDictation(words)
            startDictation()
        }
    }

    private func cancelDictation() {
        dictation.cancel()
        field.cancelDictation()
    }

    // MARK: Voice messages

    private func startRecording() {
        if dictation.isActive { finishDictation() }
        focused.wrappedValue = false
        recorder.contextualStrings = SpeechVocabulary.words(workspace: workspace, conversation: conversation)
        Task {
            if await !recorder.start() { showsMicrophoneDenied = true }
        }
    }

    private func pauseRecording() {
        Task { await recorder.pause() }
    }

    private func resumeRecording() {
        Task { await recorder.resume() }
    }

    private func deleteRecording() {
        recorder.cancel()
    }

    /// Let go, or Send: the transcript goes as the message, the recording with it. When the
    /// device heard no words, it shows as audio at once and the gateway transcribes it on the way
    /// (`ConversationModel.gatewayWords`, `docs/voice.md` §2).
    private func sendRecording() {
        Task {
            guard let recording = await recorder.finish() else {
                // Too short to be a message.
                showsHoldHint = true
                try? await Task.sleep(for: .seconds(2))
                showsHoldHint = false
                return
            }
            let transcript = recording.transcript
            if transcript.isEmpty, !conversation.usesGateway {
                try? FileManager.default.removeItem(at: recording.file)
                recordingFailure = String(localized: "No words were heard in it, and this chat can only send words. Try again, or type.")
                return
            }
            do {
                let kept = try VoiceMessageStore.keep(recording.file, as: VoiceMessageFile.name())
                conversation.sendVoiceMessage(transcript: transcript, recording: kept)
                sentVoiceMessages += 1
            } catch {
                recordingFailure = error.localizedDescription
            }
        }
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
        case .commandSend:
            if let choice = selectedSlashChoice {
                choose(choice)
            } else if conversation.canSteerHelper || conversation.canSend || conversation.canSendFollowUp || conversation.editingQueued != nil {
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
        case .modeMenu:
            // iPad ⌥Return: the send-mode menu while a turn runs; otherwise a new line.
            guard conversation.canSendFollowUp, conversation.availableFollowUpModes.count > 1 else { return false }
            conversation.showsFollowUpMenu = true
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
            Section {
                Button("Photos", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                    .disabled(!conversation.supportsImages)
                #if os(iOS)
                if DeviceCamera.isAvailable {
                    Button("Camera", systemImage: "camera") {
                        let access = AVCaptureDevice.authorizationStatus(for: .video)
                        if access == .denied || access == .restricted { showsCameraDenied = true } else { showsCamera = true }
                    }
                    .disabled(!conversation.supportsImages)
                }
                #endif
            } header: {
                // Why they're greyed out (`docs/setup.md` §3).
                if !conversation.supportsImages { Text("This model can't read pictures") }
            }
            Button("Files", systemImage: "folder") { showsFileImporter = true }
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

/// The one tinted control: Talk when there's nothing to send, Send with content (or a
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
        // A file alone is something to send too.
        if conversation.hasDraftText || !conversation.attachments.isEmpty || !conversation.files.isEmpty || !conversation.skills.isEmpty
            || conversation.draftCommand != nil || onVoiceMode == nil { return .send }
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
        switch mode {
        case .stop: return !conversation.isStopping
        case .send:
            if conversation.helperSteerTarget != nil { return conversation.hasDraftText }
            // A command waits for its argument before Send turns on (`composerCommand`).
            if conversation.draftCommand != nil { return conversation.canSendCommand }
            if conversation.editingQueued != nil { return true }
            return conversation.isWorking ? conversation.canSendFollowUp : conversation.canSend || conversation.canSendQueued
        // Talk needs the gateway there; a message waits for it.
        case .voice: return !isOffline
        }
    }

    /// What Send does while a turn runs: "Send, Steer".
    private var sendLabel: LocalizedStringKey {
        // A question on show takes what's typed as its answer (`docs/quick-actions.md` §1).
        if conversation.typedAnswerRequest != nil { return "Send Answer" }
        return "Send, \(conversation.followUpMode.title)"
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
                .animation(Theme.snappy) { $0.opacity(isEnabled ? 1 : 0.35) }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        // While a turn runs ⌘Return redirects; the field handles it.
        .keyboardShortcut(mode == .send && !conversation.isWorking ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .accessibilityLabel(mode == .stop ? "Stop" : mode == .send ? (conversation.helperSteerTarget != nil ? "Send to helper" : conversation.isWorking ? sendLabel : "Send") : "Talk")
        .help(mode == .stop ? "Stop (⌘.)" : mode == .send ? "Send (⌘↩)" : "Talk (⌥⌘V)")
    }
}

// MARK: - Dictation row

/// While dictating, the controls row becomes Cancel, a live level meter, the elapsed time and Done.
private struct DictationRow: View {
    let dictation: DictationController
    let onCancel: () -> Void
    let onDone: () -> Void
    /// Another language was picked: dictation starts again in it.
    var onLanguage: () -> Void = {}

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
            if let progress = dictation.downloadProgress {
                // The speech model downloads once per language (`docs/voice.md` §5).
                VStack(alignment: .leading, spacing: 4) {
                    let language = dictation.locale ?? .current
                    Text("Downloading \(Locale.current.localizedString(forIdentifier: language.identifier) ?? "") for dictation · \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    ProgressView(value: progress)
                        .tint(Theme.primaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            } else if dictation.state == .preparing {
                Spinner()
                    .frame(maxWidth: .infinity)
            } else {
                LevelMeter(levels: dictation.levels)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .accessibilityLabel("Listening")
            }
            DictationLanguageMenu(onChange: onLanguage)
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

/// Dictation couldn't start or stopped with an error: what happened, Try Again and close.
private struct DictationFailureRow: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: onRetry)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primaryText)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Close")
        }
        .frame(minHeight: 36)
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

/// When the "/" menu's catalog is asked for again: the chat starting to use the gateway protocol,
/// or its connection coming up.
private struct CatalogTrigger: Hashable {
    var usesGateway: Bool
    var connected: Bool
}
