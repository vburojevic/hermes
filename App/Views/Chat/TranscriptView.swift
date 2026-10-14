import HermesKit
import SwiftUI

/// The scrolling conversation, following new output while the reader is at the bottom.
struct TranscriptView: View {
    let conversation: ConversationModel
    let workspace: BotWorkspace

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    /// A fold was just tapped: size changes keep the top in place, so what was tapped stays put and
    /// opens downward, instead of the bottom anchor pushing it up the screen.
    @State private var keepsTop = false
    @State private var keepsTopReset: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                let rows = conversation.rows
                let separators = Self.separators(in: rows)
                ForEach(rows) { item in
                    VStack(alignment: .leading, spacing: 30) {
                        if let date = separators[item.id] {
                            DateSeparator(date: date)
                        }
                        row(for: item)
                    }
                    .id(item.id)
                    .transition(Self.insertion(for: item))
                }
                ForEach(conversation.processes) { process in
                    ProcessCard(process: process, onStop: { conversation.stopProcess(process) }, onDismiss: { conversation.dismissProcess(process) })
                }
                ForEach(conversation.asides) { aside in
                    AsideCard(aside: aside) { conversation.dismissAside(aside) }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // While a turn runs the card is about an earlier one, and its Try Again can't act yet.
                if let failure = conversation.turnError, !conversation.isWorking {
                    TurnErrorRow(
                        failure: failure,
                        retry: conversation.retryLastMessage,
                        reload: conversation.reload,
                        dismiss: conversation.dismissTurnError
                    )
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: conversation.sentTurns)
            .animation(Theme.spring, value: conversation.asides)
            .frame(maxWidth: Theme.readableWidth)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .environment(\.references, references)
        .environment(\.disclosureWillToggle, DisclosureAction {
            keepsTop = true
            keepsTopReset?.cancel()
            keepsTopReset = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                keepsTop = false
            }
        })
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // An approval card, banner or the keyboard shrinking the view keeps the latest step in sight;
        // a fold the person opens grows downward from where they tapped.
        .defaultScrollAnchor(keepsTop ? .top : .bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 72
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onChange(of: followToken) {
            if isAtBottom {
                position.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: conversation.sentTurns) {
            withAnimation(Theme.spring) {
                position.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                Button {
                    withAnimation(Theme.spring) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Scroll to latest")
            }
        }
        .animation(Theme.snappy, value: isAtBottom)
        .task {
            // Lazy rows estimate their heights, so the initial bottom anchor can fall short
            // on long transcripts; settle on the real bottom once they've been measured.
            for delay in [50, 250] {
                try? await Task.sleep(for: .milliseconds(delay))
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Your message rises from the composer; replies and Bot messages fade up into place.
    private static func insertion(for item: TranscriptItem) -> AnyTransition {
        switch item {
        case .user(let entry) where entry.sender == nil && entry.routineName == nil:
            .asymmetric(
                insertion: .offset(y: 24).combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)).combined(with: .opacity),
                removal: .identity
            )
        default:
            .asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .identity)
        }
    }

    /// Time separators (`dateSeparator`): before the first message of each day and after a gap
    /// of more than an hour.
    static func separators(in rows: [TranscriptItem]) -> [String: Date] {
        var result: [String: Date] = [:]
        var previous: Date?
        let calendar = Calendar.current
        for row in rows {
            let date: Date? = switch row {
            case .user(let entry): entry.timestamp
            case .assistant(let turn): turn.startedAt
            case .command(let command): command.timestamp
            case .notice: nil
            }
            guard let date else { continue }
            if let previous {
                if !calendar.isDate(date, inSameDayAs: previous) || date.timeIntervalSince(previous) > 3600 {
                    result[row.id] = date
                }
            } else if !calendar.isDateInToday(date) || rows.count > 2 {
                result[row.id] = date
            }
            previous = date
        }
        return result
    }

    /// What this chat's text can name: its gateway's Bots, files, and the skills and commands
    /// it knows. Drawn as pills and cards.
    private var references: ReferenceContext {
        ReferenceContext(workspace: workspace, catalog: conversation.slashCatalog)
    }

    /// Changes whenever streamed content grows; cheap counters, no transcript rebuild.
    private var followToken: Int {
        let base = conversation.items.count &* 31 &+ (conversation.pendingUser == nil ? 0 : 1)
        guard let live = conversation.live else { return base }
        return base &+ live.pendingText.count &+ live.turn.answer.count &+ live.turn.steps.count &* 7919
    }

    @ViewBuilder
    private func row(for item: TranscriptItem) -> some View {
        switch item {
        case .user(let entry):
            if let sender = entry.sender {
                AgentMessageRow(entry: entry, sender: sender, roster: workspace.roster)
            } else if let routine = entry.routineName {
                RoutineDeliveryRow(entry: entry, name: routine)
            } else if let command = command(in: entry) {
                CommandBubble(name: command.name, argument: command.argument, isBotChat: conversation.isBotChat)
            } else {
                UserBubble(entry: entry, images: conversation.images(for: entry), conversation: conversation.isBotChat ? nil : conversation, reactions: conversation.reactions[entry.id] ?? [])
            }
        case .assistant(let turn):
            AssistantTurnView(
                turn: turn,
                status: turn.isWorking ? conversation.liveStatus : nil,
                isStopping: turn.isWorking && conversation.isStopping,
                onBranch: branchAction(for: turn.id)
            )
        case .notice(let notice) where notice.kind == "background":
            BackgroundCard(prompt: conversation.backgroundResults[notice.id]?.prompt ?? "", answer: conversation.backgroundResults[notice.id]?.answer ?? notice.text)
        case .notice(let notice) where notice.kind.hasPrefix("receipt:"):
            ReceiptRow(notice: notice, conversation: conversation)
        case .notice(let notice):
            NoticeRow(notice: notice)
        case .command(let command):
            CommandRow(entry: command, isBotChat: conversation.isBotChat)
        }
    }

    /// A message that is a command renders as a command card: kept from when it was sent, or
    /// a leading `/word` the app or gateway knows in text from another client.
    private func command(in entry: UserEntry) -> MessageParts.Command? {
        if let parts = entry.parts { return parts.command }
        guard entry.skillNames.isEmpty, entry.fileNames.isEmpty, let parsed = SlashCommands.parse(entry.text) else { return nil }
        if conversation.slashCatalog?.skillNames.contains(parsed.name) == true { return nil }
        if SlashCommands.known(parsed.name) != nil || conversation.slashCatalog?.commands.contains(where: { $0.name == parsed.name }) == true {
            return MessageParts.Command(name: parsed.name, argument: parsed.argument)
        }
        return nil
    }

    /// Holds the conversation, not a fresh closure, so finished turns compare equal and don't
    /// re-render while a reply streams.
    private func branchAction(for itemID: String) -> BranchAction? {
        guard !conversation.isBotChat else { return nil } // Bot Chats are one conversation
        guard let key = conversation.stableKey, workspace.session(forKey: key) != nil,
              workspace.capabilities?.features.sessionFork != false || conversation.canBranchFromPoint
        else { return nil }
        let latest = conversation.items.last { if case .assistant = $0 { true } else { false } }?.id
        return BranchAction(conversation: conversation, itemID: itemID, isLatest: latest == itemID)
    }
}

/// "Today 09:41" between turns (`dateSeparator`).
private struct DateSeparator: View {
    let date: Date

    private var label: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.tertiaryText)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(notice.text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

private struct TurnErrorRow: View {
    let failure: TurnFailure
    let retry: () -> Void
    let reload: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            HStack(spacing: 8) {
                if failure.canRetry {
                    Button("Try Again", action: retry)
                        .prominentGlassButton()
                } else {
                    Button("Reload", action: reload)
                        .prominentGlassButton()
                }
                Button("Dismiss", action: dismiss)
                    .glassButton()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.Radius.card)
    }
}
