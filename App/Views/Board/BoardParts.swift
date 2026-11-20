import HermesKit
import SwiftUI

// The Board's blocks (`blocks/kanban.elyx`). Content, never glass: cards sit on surface fills;
// only the bottom action bars and menus are glass. Ink is the only action tint.

/// A Bot's face on the board, or a plain disc for a profile the roster doesn't know.
struct BoardFace: View {
    let model: BoardModel
    let profile: String?
    var size: CGFloat = 16
    var working = false

    var body: some View {
        if let appearance = model.appearance(of: profile) {
            BotFace(appearance: appearance, size: size, mood: working ? .working : .idle)
                .frame(width: size, height: size + 2)
        } else {
            Circle()
                .fill(Theme.controlFill)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: profile == nil ? "person.fill.questionmark" : "person.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.5, height: size * 0.5)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityHidden(true)
        }
    }
}

/// One card (`kanbanCard` and its variants): badge, title, the latest summary or the start of the
/// body, then who has it, sub-card progress, comments and the short id.
struct BoardCardView: View {
    let model: BoardModel
    let card: BoardCard
    var isSelected = false
    var isDimmed = false

    @State private var isHovered = false

    private var state: BoardCardState { model.state(of: card) }
    private var extras: BoardCardExtras? { model.extras[card.id] }

    private var outline: (color: Color, width: CGFloat) {
        switch state {
        case .running: (Theme.ink, 1.5)
        case .stale: (Theme.warning, 1.5)
        default: isSelected ? (Theme.ink, 1.5) : (isHovered ? Theme.separator : Theme.hairline, isHovered ? 1 : 0.5)
        }
    }

    private var summary: String? {
        switch state {
        case .gaveUp:
            return card.lastFailureError ?? card.latestSummary
        case .parent(_, let total):
            return card.latestSummary ?? String(localized: "Split into \(total) cards.")
        default:
            if let summary = card.latestSummary, !summary.isEmpty { return summary }
            return card.body.map { String($0.prefix(200)) }
        }
    }

    private var who: String {
        let name = model.name(of: card.assignee)
        if case .review = state, card.assignee != nil { return String(localized: "\(name) reviewing") }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let badge = BoardCopy.badge(for: state, checks: extras?.checks, now: model.now) {
                TagLabel(title: badge.title, symbol: badge.symbol, style: badge.style)
            }
            Text(card.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDone ? Theme.secondaryText : Theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            if let summary, !isDone {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(outline.color, lineWidth: outline.width)
        }
        // Hover lifts the card with a stronger edge and a soft shadow; it never moves, so it
        // holds under Reduce Motion too (`docs/board.md` §6).
        .shadow(color: .black.opacity(isHovered && !isDimmed ? 0.08 : 0), radius: 6, y: 2)
        .opacity(isDimmed ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isDone: Bool {
        if case .done = state { true } else { false }
    }

    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 11

    private var footer: some View {
        HStack(spacing: 6) {
            BoardFace(model: model, profile: card.assignee, working: isRunning)
            Text(who)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if case .parent(let done, let total) = state {
                Image(systemName: "checklist")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(Theme.tertiaryText)
                Text("\(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
            if card.commentCount > 0 {
                Image(systemName: "bubble.left")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(Theme.tertiaryText)
                Text("\(card.commentCount)")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
            Text(card.shortID)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// Title, state, assignee, then comments (`docs/board.md` §6). A split card's state is its
    /// sub-card progress, so it's said once, in the state's place.
    private var accessibilityText: String {
        var parts = [card.title]
        if let spoken = BoardCopy.spoken(state, checks: extras?.checks, now: model.now) { parts.append(spoken) }
        parts.append(who)
        if card.commentCount > 0 {
            parts.append(card.commentCount == 1 ? String(localized: "1 comment") : String(localized: "\(card.commentCount) comments"))
        }
        return parts.joined(separator: ", ")
    }
}

/// A column's title and count (`kanbanColumnHeader`), with + where cards can be added by hand.
struct BoardColumnHeader: View {
    let title: String
    let count: Int
    var onAdd: (() -> Void)?

    @ScaledMetric(relativeTo: .subheadline) private var plusSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var target: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(Theme.tertiaryText)
                .monospacedDigit()
            Spacer(minLength: 0)
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: plusSize, weight: .regular))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: target, height: target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "New Card in \(title)"))
                .help(String(localized: "New Card in \(title)"))
            }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }
}

/// The iPhone's column switcher chip (`columnChip`, `Selected`, `Attention`).
struct ColumnChip: View {
    let title: String
    let count: Int
    var attention: Int = 0
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? Theme.inkForeground : Theme.primaryText)
                if attention > 0, !isSelected {
                    Text("\(count) · \(String(localized: "\(attention) needs you"))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .monospacedDigit()
                } else {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? Theme.inkForegroundSecondary : Theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            // Grows with the text at the larger sizes instead of letting it spill past the capsule.
            .padding(.vertical, 4)
            .frame(minHeight: 32)
            .background(isSelected ? Theme.ink : Theme.controlFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// The PR and its required checks (`checksCard`, `Failing`) from the latest `pr_acceptance`.
struct BoardChecksCard: View {
    let checks: BoardChecks
    var branch: String?

    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var glyphSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var arrowSize: CGFloat = 12

    private var title: String {
        let pr = checks.prNumber.map { "PR #\($0)" } ?? String(localized: "The PR")
        if checks.ok { return String(localized: "\(pr) · all required checks passed") }
        if checks.failingCount == 1 { return String(localized: "\(pr) · 1 required check failed") }
        if checks.failingCount > 1 { return String(localized: "\(pr) · \(checks.failingCount) required checks failed") }
        if checks.pendingCount > 0 { return String(localized: "\(pr) · checks still running") }
        return String(localized: "\(pr) · checks couldn't be read")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let url = checks.prURL, WebLink.isWeb(url) { openURL(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: glyphSize))
                        .foregroundStyle(Theme.secondaryText)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if checks.prURL != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: arrowSize))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(checks.prURL == nil)
            .accessibilityHint(checks.prURL == nil ? "" : String(localized: "Opens the pull request"))
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ForEach(checks.checks) { check in
                checkRow(check)
            }
            if let detail = checks.detail, checks.checks.isEmpty {
                Text(BoardCopy.refusal(detail))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            if let footer = footerText {
                Text(footer)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footerText: String? {
        var parts: [String] = []
        if let sha = checks.headSHA { parts.append(String(localized: "On commit \(String(sha.prefix(7)))")) }
        if let branch { parts.append(branch) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func checkRow(_ check: BoardChecks.Check) -> some View {
        Button {
            if let url = check.url, WebLink.isWeb(url) { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(check))
                    .font(.system(size: glyphSize))
                    .foregroundStyle(color(check))
                Text(check.name)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(outcome(check))
                    .font(.footnote)
                    .foregroundStyle(check.failed ? Theme.danger : Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ check: BoardChecks.Check) -> String {
        if check.passed { return "checkmark.circle.fill" }
        if check.classification == "pending" { return "clock.fill" }
        return "xmark.circle.fill"
    }

    private func color(_ check: BoardChecks.Check) -> Color {
        if check.passed { return Theme.success }
        if check.classification == "pending" { return Theme.tertiaryText }
        return Theme.danger
    }

    private func outcome(_ check: BoardChecks.Check) -> String {
        switch check.classification {
        case "success": String(localized: "Passed")
        case "failure": String(localized: "Failed")
        case "pending": String(localized: "Running")
        case "missing": String(localized: "Didn't run")
        case "stale": String(localized: "Old commit")
        default: String(localized: "Couldn't read")
        }
    }
}

/// One attempt (`kanbanRunRow`, `Crashed`): number, when, outcome.
struct BoardRunRow: View {
    let model: BoardModel
    let run: BoardRun
    let number: Int

    private var outcome: (title: String, style: TagLabel.Style) {
        if run.isActive { return (String(localized: "Running"), .ink) }
        switch run.outcome ?? run.status {
        case "completed", "done": return (String(localized: "Done"), .success)
        case "review_requested": return (String(localized: "In review"), .neutral)
        case "blocked": return (String(localized: "Asked you"), .warning)
        case "crashed": return (String(localized: "Crashed"), .danger)
        case "timed_out": return (String(localized: "Timed out"), .danger)
        case "gave_up": return (String(localized: "Gave up"), .danger)
        case "reclaimed": return (String(localized: "Stopped"), .neutral)
        default: return ((run.outcome ?? run.status).replacingOccurrences(of: "_", with: " ").capitalized, .neutral)
        }
    }

    private var title: String {
        let when = run.isActive && run.startedAt.map({ model.now.timeIntervalSince($0) < 120 }) == true
            ? String(localized: "now")
            : run.startedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return String(localized: "Attempt \(number) · \(when)")
    }

    private var detail: String {
        if run.isActive {
            let started = run.startedAt.map { String(localized: "Started \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "Started")
            guard let heard = run.lastHeartbeatAt else { return started }
            return String(localized: "\(started) · last heard \(BoardCopy.ago(heard, now: model.now))")
        }
        var parts: [String] = []
        if let start = run.startedAt, let end = run.endedAt { parts.append(String(localized: "Ran \(BoardCopy.duration(end.timeIntervalSince(start)))")) }
        if let error = run.error, !error.isEmpty { parts.append(BoardCopy.cardWords(error)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            BoardFace(model: model, profile: run.profile, size: 22, working: run.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TagLabel(title: outcome.title, style: outcome.style)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

/// One event in plain words (`kanbanEventRow`).
struct BoardEventRow: View {
    let line: BoardActivityLine
    let date: Date?

    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 11
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = 14

    private var color: Color {
        switch line.tone {
        case .plain: Theme.tertiaryText
        case .good: Theme.success
        case .attention: Theme.warning
        case .bad: Theme.danger
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: line.symbol)
                .font(.system(size: glyphSize))
                .foregroundStyle(color)
                .frame(width: glyphWidth)
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let date {
                Text(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A blocked card's question (`needsInputCard`): who's waiting, the question, a reply field and
/// Reply and Continue (a comment, then Ready).
struct NeedsInputCard: View {
    let model: BoardModel
    let card: BoardCard
    let question: String

    @State private var reply = ""
    @State private var isSending = false
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && model.isOnline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BoardFace(model: model, profile: card.assignee, size: 22)
                Text("\(model.name(of: card.assignee)) is waiting for you")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.warning)
            }
            Text(question)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Your answer"), text: $reply, axis: .vertical)
                .focused($focused)
                .font(.body)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .textFieldStyle(.plain)
            Button {
                send()
            } label: {
                Text(isSending ? String(localized: "Sending…") : String(localized: "Reply and Continue"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.ink, in: Capsule())
                    .contentShape(Capsule())
                    .opacity(canSend ? 1 : 0.35)
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSend)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.warning, lineWidth: 1)
        }
        .onChange(of: focused) { _, focused in model.isTyping = focused }
    }

    private func send() {
        isSending = true
        Task {
            if await model.reply(card, text: reply) {
                reply = ""
                focused = false
            }
            isSending = false
        }
    }
}

/// The project home's Board row (`boardSummaryRow`): running, in review, done, and what needs you.
struct BoardSummaryRow: View {
    let model: BoardModel
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var detail: String {
        guard model.phase == .ready, !model.boardMissing else { return String(localized: "Cards Hermes and its Bots work through") }
        if model.allCards.isEmpty { return String(localized: "No cards yet") }
        var parts: [String] = []
        if model.runningCount > 0 { parts.append(String(localized: "\(model.runningCount) running")) }
        if model.reviewCount > 0 { parts.append(String(localized: "\(model.reviewCount) in review")) }
        parts.append(String(localized: "\(model.doneCount) done"))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            Group {
                // At the accessibility sizes the tile sits above, what needs you drops under the
                // counts and the chevron goes, so every word shows (`docs/projects.md` §5).
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        tile
                        title
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.needsYouCount > 0 { needsYou }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 12) {
                        tile
                        VStack(alignment: .leading, spacing: 1) {
                            title
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.needsYouCount > 0 { needsYou.fixedSize() }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Opens the project's board"))
        // Counts stay live while the home is on screen; visiting the home makes no board.
        .onAppear { model.appear(creating: false) }
        .onDisappear { model.disappear() }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.ink)
            .frame(width: 34, height: 34)
            .overlay {
                // The tile keeps its size, so its glyph does too.
                Image(systemName: "square.grid.2x2")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(Theme.inkForeground)
            }
    }

    private var title: some View {
        Text("Board")
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
    }

    private var needsYou: some View {
        TagLabel(title: String(localized: "\(model.needsYouCount) needs you"), style: .warning)
    }
}

// MARK: - Loading and empty (`docs/board.md` §6)

/// A card that's loading (`kanbanCardSkeleton`): a title, two lines and who has it.
struct BoardCardSkeleton: View {
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 9
    @Environment(\.colorSchemeContrast) private var contrast

    /// Control fill, a little stronger with Increase Contrast.
    private var fill: Color { contrast == .increased ? Theme.primaryText.opacity(0.16) : Theme.controlFill }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 9) {
                    bar(proxy.size.width * 0.7, titleHeight)
                    bar(proxy.size.width, lineHeight)
                    bar(proxy.size.width * 0.55, lineHeight)
                }
            }
            .frame(height: titleHeight + lineHeight * 2 + 18)
            HStack(spacing: 6) {
                Circle().fill(fill).frame(width: 16, height: 16)
                bar(52, lineHeight)
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        Capsule().fill(fill).frame(width: max(0, width), height: height)
    }
}

/// A column that's loading (`kanbanColumnSkeleton`): its head and a few cards.
struct BoardColumnSkeleton: View {
    var width: CGFloat?
    let cards: Int

    @ScaledMetric(relativeTo: .subheadline) private var headHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var nameHeight: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BoardSkeletonHead(height: headHeight, barHeight: nameHeight)
            ForEach(0..<cards, id: \.self) { _ in
                BoardCardSkeleton()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A column head that's loading: a name and a count.
private struct BoardSkeletonHead: View {
    let height: CGFloat
    let barHeight: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast
    private var fill: Color { contrast == .increased ? Theme.primaryText.opacity(0.16) : Theme.controlFill }

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(fill).frame(width: 64, height: barHeight)
            Capsule().fill(fill).frame(width: 14, height: barHeight)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: height)
    }
}

/// The iPhone board while it loads: the summary line, the switcher's chips, the first column's
/// head and three cards.
struct BoardPhoneSkeleton: View {
    @ScaledMetric(relativeTo: .footnote) private var tileSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var summaryHeight: CGFloat = 9
    @ScaledMetric(relativeTo: .subheadline) private var chipHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var headHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var nameHeight: CGFloat = 11
    @Environment(\.colorSchemeContrast) private var contrast
    private var fill: Color { contrast == .increased ? Theme.primaryText.opacity(0.16) : Theme.controlFill }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill).frame(width: tileSize, height: tileSize)
                Capsule().fill(fill).frame(width: 230, height: summaryHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .padding(.bottom, 6)
            HStack(spacing: 8) {
                Capsule().fill(fill).frame(width: 76, height: chipHeight)
                Capsule().fill(fill).frame(width: 84, height: chipHeight)
                Capsule().fill(fill).frame(width: 70, height: chipHeight)
                Capsule().fill(fill).frame(width: 92, height: chipHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            BoardSkeletonHead(height: headHeight, barHeight: nameHeight)
            BoardCardSkeleton()
            BoardCardSkeleton()
            BoardCardSkeleton()
        }
    }
}

/// The loading board's pulse. It runs only while it can be seen and holds still with Reduce
/// Motion or when decorative motion is paused; VoiceOver hears "Loading cards" once for the whole
/// skeleton (`docs/board.md` §6).
struct BoardLoadingSkeleton<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        DecorativeLoop { runs in
            if runs {
                content.modifier(BoardSkeletonPulse())
            } else {
                content
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading cards"))
    }
}

/// Fades the skeleton between full and 55% once a second. It's a separate view so that taking it
/// away (Reduce Motion, off screen) ends the repeating animation.
private struct BoardSkeletonPulse: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dimmed = true }
            }
    }
}

/// The one note on a board with no cards at all (`stateMessage`): where cards come from. On the
/// iPad and the Mac it floats over the columns as a card.
struct BoardEmptyNote: View {
    var floats = false

    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: glyphSize, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("No cards yet")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("Add one with New Card or a column's +, or ask Hermes in a chat to plan the work.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: floats ? 400 : .infinity)
        .background {
            if floats {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.sheetBackground)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
