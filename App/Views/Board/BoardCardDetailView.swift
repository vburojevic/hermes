import HermesKit
import SwiftUI

/// A card (`cardRunning`, `cardNeedsYou`, `cardReview`; the inspector in `ipadBoard` and
/// `macBoardCard`): the title, the state line and who has it, then what the state needs, the
/// description, details, comments and activity. Running cards end in Stop and Watch, reviews in
/// Reopen with Note… and Approve, on a glass bar.
struct BoardCardDetailView: View {
    let model: BoardModel
    let cardID: String
    /// In the inspector (iPad landscape, Mac): no navigation bar of its own.
    var inInspector = false

    @State private var showsAllActivity = false
    @State private var commentText = ""
    @State private var isApproving = false
    @State private var copiedLink = false
    @FocusState private var commentFocused: Bool

    private var card: BoardCard? { model.card(cardID) ?? model.details[cardID]?.card }
    private var detail: BoardCardDetail? { model.details[cardID] }

    var body: some View {
        Group {
            if let card {
                content(card)
            } else if model.phase == .loading || detail == nil {
                SkeletonRows()
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                StateMessage(symbol: "rectangle.on.rectangle.slash", title: String(localized: "This card is gone"),
                             message: String(localized: "It was archived or deleted on \(model.gatewayName)."))
            }
        }
        .background((inInspector ? Theme.sheetBackground : Theme.groupedBackground).ignoresSafeArea())
        .task(id: cardID) { await model.watchDetail(cardID) }
        .onChange(of: commentFocused) { _, focused in model.isTyping = focused }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private func content(_ card: BoardCard) -> some View {
        let state = model.state(of: card)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(card, state: state)
                switch state {
                case .running, .stale:
                    assigneeRow(card)
                    latest(card)
                    attempts
                case .needsYou:
                    NeedsInputCard(model: model, card: card, question: detail?.question ?? card.latestSummary ?? String(localized: "\(model.name(of: card.assignee)) needs an answer to go on."))
                    description(card)
                case .review:
                    review(card)
                case .gaveUp:
                    failure(card)
                    description(card)
                    attempts
                default:
                    description(card)
                    if let summary = detail?.card.latestSummary ?? card.latestSummary, !summary.isEmpty {
                        section(String(localized: "Latest")) { textCard(summary) }
                    }
                }
                details(card)
                comments(card)
                activity(card)
            }
            .padding(.horizontal, inInspector ? 18 : 16)
            .padding(.top, inInspector ? 18 : 8)
            .padding(.bottom, 24)
            .frame(maxWidth: Theme.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom) { bottomBar(card, state: state) }
        #if os(iOS)
        .navigationTitle(inInspector ? "" : card.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !inInspector {
                ToolbarItem(placement: .principal) { Text("") }
                ToolbarItem(placement: .primaryAction) { moreMenu(card) }
            }
        }
        #endif
    }

    // MARK: Header

    private func header(_ card: BoardCard, state: BoardCardState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(card.title)
                    .font(inInspector ? .title3.bold() : .title.bold())
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if inInspector { moreMenu(card) }
            }
            HStack(spacing: 8) {
                if let badge = stateBadge(state) {
                    TagLabel(title: badge.title, symbol: badge.symbol, style: badge.style)
                }
                Text(stateLine(card, state: state))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private func stateBadge(_ state: BoardCardState) -> BoardCopy.Badge? {
        if case .review = state, let checks = detail?.checks {
            return checks.ok
                ? BoardCopy.Badge(title: String(localized: "In review"), symbol: "checkmark.circle.fill", style: .success)
                : BoardCopy.reviewBadge(checks)
        }
        if case .idle = state {
            return BoardCopy.Badge(title: model.columnTitle(card?.column ?? ""), symbol: "circle.dashed", style: .neutral)
        }
        return BoardCopy.badge(for: state, checks: detail?.checks, now: model.now)
    }

    /// "Last heard 20 s ago · wt/t_a91c", "Blocked 25 min ago · Ada", "Scout reviewed · 10 min ago".
    private func stateLine(_ card: BoardCard, state: BoardCardState) -> String {
        var parts: [String] = []
        switch state {
        case .running, .stale:
            if let heard = card.lastHeartbeatAt { parts.append(String(localized: "Last heard \(BoardCopy.ago(heard, now: model.now))")) }
            if let branch = card.branchName { parts.append(branch) }
        case .needsYou, .blocked, .gaveUp:
            if let at = lastEvent(["blocked", "gave_up", "block_loop_detected"]) {
                parts.append(String(localized: "Blocked \(BoardCopy.ago(at, now: model.now))"))
            }
            parts.append(model.name(of: card.assignee))
        case .review:
            if let at = lastEvent(["review_requested", "pr_acceptance"]) {
                parts.append(String(localized: "\(model.name(of: card.assignee)) reviewed · \(BoardCopy.ago(at, now: model.now))"))
            }
            parts.append(card.shortID)
        case .done(let at):
            if let at { parts.append(at.formatted(date: .abbreviated, time: .shortened)) }
            parts.append(model.name(of: card.assignee))
        default:
            parts.append(model.name(of: card.assignee))
            parts.append(card.shortID)
        }
        return parts.joined(separator: " · ")
    }

    private func lastEvent(_ kinds: Set<String>) -> Date? {
        detail?.events.last { kinds.contains($0.kind) }?.createdAt
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var cellFill: Color { inInspector ? Theme.surface : Theme.groupedCell }

    private func textCard(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Theme.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Who has it (face, name, model), which opens the Bot.
    private func assigneeRow(_ card: BoardCard) -> some View {
        Button {
            if let profile = card.assignee { model.openBot(profile) }
        } label: {
            HStack(spacing: 12) {
                BoardFace(model: model, profile: card.assignee, size: 30, working: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name(of: card.assignee))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(model.assigneeDetail(card))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(card.assignee == nil)
    }

    /// Latest: the summary and the last lines of the worker's output.
    private func latest(_ card: BoardCard) -> some View {
        section(String(localized: "Latest")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(detail?.card.latestSummary ?? card.latestSummary ?? String(localized: "Starting…"))
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let lines = model.logs[cardID]?.lastLines(4) ?? []
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel(String(localized: "Worker output: \(lines.joined(separator: ", "))"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private var attempts: some View {
        if let runs = detail?.runs, !runs.isEmpty {
            section(String(localized: "Attempts")) {
                VStack(spacing: 0) {
                    let numbered = Array(runs.enumerated()).reversed()
                    ForEach(Array(numbered), id: \.element.id) { index, run in
                        BoardRunRow(model: model, run: run, number: index + 1)
                        if index != 0 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 48)
                        }
                    }
                }
                .padding(.vertical, 2)
                .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func description(_ card: BoardCard) -> some View {
        if let body = detail?.card.body ?? card.body, !body.isEmpty {
            section(String(localized: "Description")) { textCard(body) }
        }
    }

    @ViewBuilder
    private func failure(_ card: BoardCard) -> some View {
        if let error = card.lastFailureError {
            section(String(localized: "Why it stopped")) {
                Text(BoardCopy.cardWords(error))
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.dangerWash, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func review(_ card: BoardCard) -> some View {
        if let summary = detail?.card.latestSummary ?? card.latestSummary, !summary.isEmpty {
            section(String(localized: "Summary")) { textCard(summary) }
        }
        if let checks = detail?.checks {
            BoardChecksCard(checks: checks, branch: card.branchName)
        }
        if let refusal = model.approvalRefusals[card.id] {
            Label(refusal, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .transition(.opacity)
        }
        if let files = detail?.changedFiles, !files.isEmpty {
            section(files.count == 1 ? String(localized: "Files · 1 changed") : String(localized: "Files · \(files.count) changed")) {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        fileRow(file)
                        if index < files.count - 1 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                }
                .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        if let note = detail?.reviewerComment {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    BoardFace(model: model, profile: note.author, size: 16)
                    Text("\(model.name(of: note.author)) · review")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(note.body)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func fileRow(_ file: BoardChangedFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(file.path)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let added = file.added, added > 0 {
                Text("+\(added)")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            if let removed = file.removed, removed > 0 {
                Text("−\(removed)")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// Assigned to, priority, what it waits for and what waits for it, where it works.
    @ViewBuilder
    private func details(_ card: BoardCard) -> some View {
        let rows = detailRows(card)
        if !rows.isEmpty {
            section(String(localized: "Details")) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.0)
                                .foregroundStyle(Theme.primaryText)
                            Spacer(minLength: 12)
                            Text(row.1)
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                        if index < rows.count - 1 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                }
                .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func detailRows(_ card: BoardCard) -> [(String, String)] {
        var rows: [(String, String)] = [(String(localized: "Assigned to"), model.name(of: card.assignee))]
        rows.append((String(localized: "Priority"), card.priority > 0 ? String(localized: "Raised (\(card.priority))") : String(localized: "Normal")))
        if let parents = detail?.parentCards, !parents.isEmpty {
            rows.append((String(localized: "Starts after"), parents.map(\.title).formatted(.list(type: .and))))
        }
        if let children = detail?.childCards, !children.isEmpty {
            rows.append((String(localized: "Blocks"), children.map(\.title).formatted(.list(type: .and))))
        }
        switch card.workspaceKind {
        case "worktree": rows.append((String(localized: "Works in"), card.branchName ?? String(localized: "Its own worktree")))
        case "dir": rows.append((String(localized: "Works in"), String(localized: "The project folder")))
        case "scratch": rows.append((String(localized: "Works in"), String(localized: "A scratch folder")))
        default: break
        }
        return rows
    }

    @ViewBuilder
    private func comments(_ card: BoardCard) -> some View {
        let all = detail?.comments ?? []
        let shown: [BoardComment] = {
            if case .review = model.state(of: card), let note = detail?.reviewerComment { return all.filter { $0.id != note.id } }
            return all
        }()
        section(all.isEmpty ? String(localized: "Comments") : String(localized: "Comments · \(all.count)")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown.reversed()) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(comment.isFromPerson ? String(localized: "You") : model.name(of: comment.author)) · \(BoardCopy.ago(comment.createdAt, now: model.now))")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                        Text(comment.body)
                            .font(.body)
                            .foregroundStyle(Theme.primaryText)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 8) {
                    TextField(String(localized: "Add a comment"), text: $commentText, axis: .vertical)
                        .focused($commentFocused)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .onSubmit(addComment)
                    if !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Add", systemImage: "arrow.up.circle.fill", action: addComment)
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .foregroundStyle(Theme.ink)
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Add Comment"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func addComment() {
        guard let card else { return }
        let text = commentText
        Task {
            if await model.comment(card, text: text) {
                commentText = ""
                commentFocused = false
            }
        }
    }

    @ViewBuilder
    private func activity(_ card: BoardCard) -> some View {
        let lines: [(BoardActivityLine, Date?, Int)] = (detail?.events ?? []).reversed().compactMap { event in
            let who = model.name(of: event.payload?["profile"]?.stringValue ?? card.assignee)
            return BoardActivityLine.line(for: event, who: who, columnTitle: model.columnTitle).map { ($0, event.createdAt, event.id) }
        }
        if !lines.isEmpty {
            section(String(localized: "Activity")) {
                VStack(spacing: 0) {
                    ForEach(Array((showsAllActivity ? lines : Array(lines.prefix(8))).enumerated()), id: \.element.2) { _, line in
                        BoardEventRow(line: line.0, date: line.1)
                    }
                    if lines.count > 8 {
                        Button(showsAllActivity ? String(localized: "Show Less") : String(localized: "Show All \(lines.count)")) {
                            withAnimation(Theme.snappy) { showsAllActivity.toggle() }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 6)
                .background(cellFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    // MARK: Bars and menus

    @ViewBuilder
    private func bottomBar(_ card: BoardCard, state: BoardCardState) -> some View {
        switch state {
        case .running, .stale:
            actions(secondary: String(localized: "Stop"), secondarySymbol: "stop.fill", onSecondary: { Task { await model.stop(card) } },
                    primary: String(localized: "Watch"), symbol: "eye", onPrimary: { model.watching = card })
        case .review:
            actions(secondary: String(localized: "Reopen with Note…"), secondarySymbol: "arrow.uturn.backward", onSecondary: { model.reopening = card },
                    primary: isApproving ? String(localized: "Approving…") : String(localized: "Approve"), symbol: "checkmark",
                    primaryEnabled: !isApproving && model.isOnline) {
                isApproving = true
                Task {
                    await model.approve(card)
                    isApproving = false
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(secondary: String, secondarySymbol: String, onSecondary: @escaping () -> Void, primary: String, symbol: String,
                         primaryEnabled: Bool = true, onPrimary: @escaping () -> Void) -> some View {
        #if os(macOS)
        HStack(spacing: 10) {
            Spacer()
            Button(secondary, action: onSecondary)
                .controlSize(.large)
            Button(primary, action: onPrimary)
                .inkDefaultButton()
                .controlSize(.large)
                .disabled(!primaryEnabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        #else
        PairedSheetButtons(secondary: secondary, onSecondary: onSecondary, secondarySymbol: secondarySymbol,
                           primary: primary, symbol: symbol, primaryEnabled: primaryEnabled, minimumScale: 0.7, onPrimary: onPrimary)
        #endif
    }

    /// … : Edit, Copy Link, Split into Cards, Archive, Delete….
    private func moreMenu(_ card: BoardCard) -> some View {
        Menu {
            Button("Edit", systemImage: "pencil") { model.editing = card }
            Button("Copy Link", systemImage: "link") { Pasteboard.copy(model.link(to: card)) }
            if card.column == "triage" {
                Button("Let Hermes Write It Up", systemImage: "text.badge.star") { Task { await model.writeUp(card) } }
                Button("Split into Cards", systemImage: "square.split.2x1") { Task { await model.split(card) } }
            }
            if card.column == "ready" {
                Button("Start Now", systemImage: "play") { Task { await model.startNow() } }
            }
            Divider()
            BoardCardMenuItems(model: model, card: card, includesDestructive: false)
            Divider()
            Button("Archive", systemImage: "archivebox") { Task { await model.archive(card) } }
            Button("Delete…", systemImage: "trash", role: .destructive) { model.deleting = card }
        } label: {
            Image(systemName: "ellipsis")
                .font(inInspector ? .body.weight(.semibold) : .body)
                .frame(width: inInspector ? 28 : nil, height: inInspector ? 28 : nil)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .accessibilityLabel(String(localized: "Card actions"))
        .help(String(localized: "Card actions"))
    }
}

/// A card's moves and actions (`cardMenu`): the moves the workflow allows, in plain words,
/// then Assign To…, Raise Priority, Open Chat, Archive and Delete….
struct BoardCardMenuItems: View {
    let model: BoardModel
    let card: BoardCard
    var includesDestructive = true

    var body: some View {
        ForEach(model.moves(for: card)) { column in
            Button(String(localized: "Move to \(column.title)"), systemImage: BoardCardMenuItems.symbol(column.key)) {
                Task { await model.move(card, to: column.key) }
            }
        }
        Button("Assign To…", systemImage: "person.2") { model.assigning = card }
        Button("Raise Priority", systemImage: "arrow.up") { Task { await model.raisePriority(card) } }
        if card.sessionID != nil {
            Button("Open Chat", systemImage: "bubble.left") { model.openChat(card) }
        }
        if includesDestructive {
            Divider()
            Button("Archive", systemImage: "archivebox") { Task { await model.archive(card) } }
            Button("Delete…", systemImage: "trash", role: .destructive) { model.deleting = card }
        }
    }

    static func symbol(_ column: String) -> String {
        switch column {
        case "ready": "arrow.right.to.line"
        case "todo": "tray"
        case "triage": "tray.and.arrow.down"
        case "scheduled": "clock"
        case "blocked": "pause.circle"
        case "review": "eye"
        case "done": "checkmark.circle"
        default: "arrow.right"
        }
    }
}
