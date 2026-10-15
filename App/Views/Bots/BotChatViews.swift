import HermesKit
import SwiftUI

/// The Bot Chat's title: face, name and what the Bot is up to.
struct BotChatTitle: View {
    let roster: BotRoster
    let botName: String
    let conversation: ConversationModel

    @State private var isDelighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bot: BotProfile? { roster.bot(named: botName) }

    /// What the Bot is doing (`docs/bot-faces.md` §5.1): thinking and working with the turn, a happy
    /// squint when a reply lands, listening while the person types or dictates, asleep offline.
    private var mood: BotMood {
        if isDelighted, !conversation.isWorking { return .happy }
        return conversation.faceMood(isOnline: roster.isConnected)
    }

    private func subtitle(for bot: BotProfile?) -> String {
        if conversation.isWorking { return String(localized: "Thinking…") }
        if roster.isActive(botName) { return String(localized: "Active now") }
        if roster.isBusy(botName) { return String(localized: "Working in the background") }
        return "@\(bot?.mentionTag ?? botName)"
    }

    var body: some View {
        let bot = self.bot
        let subtitle = subtitle(for: bot)
        let highlighted = conversation.isWorking || roster.isActive(botName)
        Button {
            roster.editingBot = botName
        } label: {
            HStack(spacing: 9) {
                if let bot {
                    BotFace(appearance: roster.appearance(for: bot), size: 32, mood: mood, boopable: true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(bot?.title ?? botName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    // A little ticker: the new status rolls up as the old one leaves.
                    ZStack(alignment: .leading) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(conversation.isWorking ? Theme.warning : highlighted ? Theme.success : Theme.secondaryText)
                            .lineLimit(1)
                            .id(subtitle)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .offset(y: 9).combined(with: .opacity),
                                removal: .offset(y: -9).combined(with: .opacity)
                            ))
                    }
                    .clipped()
                }
            }
            // The face sits as far from the capsule's end as from its top; the text gets room to breathe.
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(bot?.title ?? botName), \(subtitle)"))
        .accessibilityHint("Edit this Bot")
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: subtitle)
        .task(id: conversation.completedTurns) {
            guard conversation.completedTurns > 0 else { return }
            isDelighted = true
            try? await Task.sleep(for: .seconds(1.8))
            isDelighted = false
        }
    }
}

/// A Bot Chat before the first message: the Bot introduces itself.
struct BotHelloView: View {
    let roster: BotRoster
    let botName: String
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    let centersComposer: Bool
    var composerFocused: Binding<Bool>

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bot: BotProfile? { roster.bot(named: botName) }

    private var faceSize: CGFloat { 120 }

    private var mood: BotMood {
        conversation.faceMood(isOnline: roster.isConnected)
    }

    var body: some View {
        // Short spaces (landscape with the keyboard up) drop the hello, then everything.
        ViewThatFits(in: .vertical) {
            hello
            if !centersComposer {
                VStack {
                    Spacer(minLength: 0)
                    BotSuggestionChips(roster: roster, botName: botName, conversation: conversation, focused: composerFocused, centered: false)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            Color.clear
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.05)) {
                appeared = true
            }
        }
    }

    private var hello: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                if let bot {
                    // Tap to boop: it squashes, smiles and sparkles (the face does it all).
                    BotFace(appearance: roster.appearance(for: bot), size: faceSize, mood: mood, boopable: true)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                        .opacity(appeared ? 1 : 0)
                }
                VStack(spacing: 6) {
                    Text(bot?.title ?? botName)
                        .font(.system(.title, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(bot?.role ?? String(localized: "Your Bot keeps one continuous chat with you, its own memory, and routines that run on a schedule."))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 6)
            }
            // Centred on iPad and Mac: the hello sits right above the composer, which the chat
            // screen lifts to the middle (and glides down on the first send).
            if centersComposer {
                Spacer().frame(height: 28)
            } else {
                Spacer(minLength: 24)
                BotSuggestionChips(roster: roster, botName: botName, conversation: conversation, focused: composerFocused, centered: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .opacity(appeared ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// Things to try in a Bot's first chat, plus its routines, as chips.
struct BotSuggestionChips: View {
    let roster: BotRoster
    let botName: String
    @Bindable var conversation: ConversationModel
    var focused: Binding<Bool>
    let centered: Bool

    private var suggestions: [(title: String, symbol: String, prompt: String)] {
        [
            (String(localized: "Introduce yourself"), "hand.wave", ConversationModel.kickoffText),
            (String(localized: "What can you do?"), "sparkles", String(localized: "What can you help me with? Give me a few ideas.")),
            (String(localized: "Set up a routine"), "alarm", String(localized: "Help me set up a daily routine for you: ")),
        ]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button {
                        conversation.draft = suggestion.prompt
                        focused.wrappedValue = true
                    } label: {
                        ChipLabel(title: suggestion.title, symbol: suggestion.symbol)
                    }
                    .buttonStyle(PressableStyle())
                }
                Button {
                    roster.routinesBot = botName
                } label: {
                    ChipLabel(title: String(localized: "Routines"), symbol: "calendar.badge.clock")
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
        .frame(maxWidth: centered ? 680 : .infinity)
    }
}

/// A message another Bot sent this one (`message_agent`), shown as theirs, not the person's.
struct AgentMessageRow: View {
    let entry: UserEntry
    let sender: AgentSender
    let roster: BotRoster?

    /// A hand-off just arrived: the sender looks up at the Bot it's handing work to (in the
    /// header) for 0.6 s (`docs/bot-faces.md` §5.8); that Bot then starts thinking.
    @State private var handingOff = false

    var body: some View {
        let senderBot = roster?.bot(handle: sender.handle)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let roster, let bot = senderBot {
                    BotFace(appearance: roster.appearance(for: bot), size: 28, look: handingOff ? CGVector(dx: 0.5, dy: -1) : nil)
                        .task {
                            guard let date = entry.timestamp, Date.now.timeIntervalSince(date) < 8 else { return }
                            handingOff = true
                            try? await Task.sleep(for: .seconds(0.6))
                            handingOff = false
                        }
                } else {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(senderBot?.title ?? sender.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("@\(sender.handle)")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                if let date = entry.timestamp {
                    Spacer(minLength: 4)
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Text(entry.text)
                .font(Theme.Typography.message)
                .lineSpacing(Theme.Typography.messageLineSpacing)
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .padding(.trailing, 40)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(entry.text) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Message from \(senderBot?.title ?? sender.name): \(BotMentions.stripMarkdown(entry.text))"))
    }
}

/// A routine's output, delivered into the Bot Chat on schedule. With a reply after it (the Bot
/// passing the output on, often word for word) it folds to its header and a line, and opens on
/// a tap; on its own it shows in full.
struct RoutineDeliveryRow: View {
    let entry: UserEntry
    let name: String
    var isAnswered = false

    @State private var isOpen = false
    @Environment(\.disclosureWillToggle) private var willToggle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var folds: Bool { isAnswered && !entry.text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if folds {
                Button {
                    willToggle()
                    withAnimation(Disclosure.animation(reduceMotion: reduceMotion)) { isOpen.toggle() }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? "Hides the routine's output" : "Shows the routine's output")
            } else {
                header
            }
            if !entry.text.isEmpty {
                if folds, !isOpen {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                } else {
                    MarkdownView(text: entry.text, tone: .secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .padding(.trailing, 40)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(entry.text) }
        }
        .accessibilityElement(children: folds ? .combine : .ignore)
        .accessibilityLabel(Text("Routine \(name): \(folds && !isOpen ? preview : BotMentions.stripMarkdown(entry.text))"))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "alarm.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
            Text("Routine")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let date = entry.timestamp {
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if folds {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    /// The output's first line of text, without its Markdown.
    private var preview: String {
        BotMentions.stripMarkdown(entry.text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// Shown in Bots mode before a Bot is picked: everyone, as faces.
/// Bots mode's home: every Bot as a tile, pinned first, with what each is up to
/// (Elyx `screens/iphone/bots-home.elyx`, `macBots`; tiles are `Bots.botTile`).
struct BotsHomeView: View {
    let roster: BotRoster
    @Bindable var workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WindowRouter.self) private var router: WindowRouter?

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 12, alignment: .top)]
        #endif
    }

    /// Before the first list: what the connection is doing, not a spinner that never says it gave up.
    @ViewBuilder
    private var notLoaded: some View {
        switch roster.state {
        case .connecting, .idle, .online:
            SidebarState(isLoading: true, title: String(localized: "Connecting to your Bots…"))
        case .signInRequired(let message):
            SidebarState(
                symbol: "person.badge.key",
                title: String(localized: "Sign in to see your Bots"),
                message: message,
                actionTitle: String(localized: "Sign In…")
            ) {
                router?.sheet = .editGateway(workspace.bot)
            }
        case .failed(let message):
            SidebarState(
                symbol: "wifi.slash",
                title: String(localized: "Can't reach your Bots"),
                message: message.isEmpty ? String(localized: "Check that hermes serve is running on \(workspace.bot.name), then try again.") : message,
                actionTitle: String(localized: "Retry")
            ) {
                Task { await roster.reconnectNow() }
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            if !roster.hasLoaded {
                notLoaded
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(Array(roster.visibleBots.enumerated()), id: \.element.id) { index, bot in
                                Button {
                                    workspace.selection = .bot(bot.name)
                                } label: {
                                    BotTile(roster: roster, bot: bot)
                                }
                                .buttonStyle(PressableStyle())
                                .contextMenu { BotActions(roster: roster, bot: bot) }
                                .opacity(appeared || reduceMotion ? 1 : 0)
                                .offset(y: appeared || reduceMotion ? 0 : 14)
                                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78).delay(Double(index) * 0.045), value: appeared)
                            }
                            Button {
                                roster.isCreatingBot = true
                            } label: {
                                NewBotTile()
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(!roster.isConnected)
                        }
                    }
                    #if os(macOS)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 1000, alignment: .leading)
                    #else
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 820, alignment: .leading)
                    #endif
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { appeared = true }
            }
        }
        .animation(reduceMotion ? nil : Theme.spring, value: roster.visibleBots.map(\.name))
        .navigationTitle("Bots")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .toolbar {
            if let onToggleSidebar {
                ToolbarItem(placement: .navigation) {
                    Button(action: onToggleSidebar) {
                        SidebarGlyph()
                    }
                    .accessibilityLabel("Show sidebar")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    roster.isCreatingBot = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Bot")
                .help("New Bot (⇧⌘N)")
                .disabled(!roster.isConnected)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(macOS)
            Text("Bots")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            #else
            Text("Your Bots")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            #endif
            Text("Each Bot has its own memory, one chat that never resets, and routines that run on a schedule.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

/// A Bot on the home grid: face, name, @handle, role, and a line on what it's doing.
private struct BotTile: View {
    let roster: BotRoster
    let bot: BotProfile

    @State private var isHovered = false

    private var isUnread: Bool { roster.unread.contains(bot.name) }

    private var mood: BotMood {
        let mood = roster.faceMood(for: bot.name)
        return mood == .idle && isHovered ? .listening : mood
    }

    /// Working, new, active or quiet: the dot's colour and the line beside it.
    private var status: (color: Color, text: String) {
        if roster.isBusy(bot.name) {
            let detail = roster.workingStatus(bot.name)
            return (Theme.warning, detail.map { String(localized: "Working: \($0)") } ?? String(localized: "Working"))
        }
        if isUnread, let preview = bot.preview {
            return (Theme.success, String(localized: "New: \(preview)"))
        }
        if roster.isActive(bot.name) {
            return (Theme.success, String(localized: "Active now"))
        }
        if let date = bot.lastActive {
            return (Theme.tertiaryText, String(localized: "Last active \(Formatting.relativePhrase(date))"))
        }
        return (Theme.tertiaryText, String(localized: "Say hi to start"))
    }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                BotFace(appearance: roster.appearance(for: bot), size: 56, mood: mood, boopable: true)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if bot.meta.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .accessibilityHidden(true)
                    }
                    if isUnread {
                        Circle()
                            .fill(Theme.unread)
                            .frame(width: 10, height: 10)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text("@\(bot.mentionTag)")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                if let role = bot.role {
                    Text(role)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            HStack(spacing: 6) {
                StatusDot(color: status.color, pulsing: roster.isBusy(bot.name))
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .onHover { hovering in
            withAnimation(Theme.snappy) { isHovered = hovering }
        }
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isUnread)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([bot.title, isUnread ? String(localized: "Unread") : nil, bot.meta.isPinned ? String(localized: "Pinned") : nil, bot.role, status.text].compactMap(\.self).joined(separator: ", ")))
    }
}

/// The last tile on the grid: a dashed outline that makes a new Bot.
private struct NewBotTile: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 48, height: 48)
                .background(Theme.surface, in: Circle())
            Text("New Bot")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("A name, a face and its own chat")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The roster's Bots matching an `@word` being typed, for the composer's menu (`composerMention`).
enum MentionSuggestions {
    static func matches(_ query: String, roster: BotRoster, excluding activeBot: String?) -> [BotProfile] {
        roster.visibleBots.filter { bot in
            guard bot.name != activeBot else { return false }
            guard !query.isEmpty else { return true }
            return bot.mentionTag.hasPrefix(query) || bot.handle.hasPrefix(query)
                || bot.title.lowercased().split(separator: " ").contains { $0.hasPrefix(query) }
        }
        .prefix(6)
        .map { $0 }
    }
}

extension ConversationModel {
    /// The Bot face for this chat (`docs/bot-faces.md` §5.1): asleep offline or once the gateway
    /// rests the chat, thinking and working with the turn, listening while the person types or
    /// dictates.
    func faceMood(isOnline: Bool) -> BotMood {
        if !isOnline || isResting && !isWorking { return .sleeping }
        if turnMood != .idle { return turnMood }
        return hasDraftText || isDictating ? .listening : .idle
    }
}
