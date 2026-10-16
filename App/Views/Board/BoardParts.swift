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
                        .font(.system(size: size * 0.5))
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

    private var state: BoardCardState { model.state(of: card) }
    private var extras: BoardCardExtras? { model.extras[card.id] }

    private var outline: (color: Color, width: CGFloat) {
        switch state {
        case .running: (Theme.ink, 1.5)
        case .stale: (Theme.warning, 1.5)
        default: isSelected ? (Theme.ink, 1.5) : (Theme.hairline, 0.5)
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
        .opacity(isDimmed ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isDone: Bool {
        if case .done = state { true } else { false }
    }

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
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Text("\(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
            if card.commentCount > 0 {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11))
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

    /// Title, state, assignee, then sub-cards and comments (`docs/board.md` §6).
    private var accessibilityText: String {
        var parts = [card.title]
        if let spoken = BoardCopy.spoken(state, checks: extras?.checks, now: model.now) { parts.append(spoken) }
        parts.append(who)
        var counts: [String] = []
        if case .parent(let done, let total) = state { counts.append(String(localized: "\(done) of \(total) sub-cards done")) }
        if card.commentCount > 0 {
            counts.append(card.commentCount == 1 ? String(localized: "1 comment") : String(localized: "\(card.commentCount) comments"))
        }
        if !counts.isEmpty { parts.append(counts.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// A column's title and count (`kanbanColumnHeader`), with + where cards can be added by hand.
struct BoardColumnHeader: View {
    let title: String
    let count: Int
    var onAdd: (() -> Void)?

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
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
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
            .frame(height: 32)
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
                if let url = checks.prURL { openURL(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if checks.prURL != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
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
            if let url = check.url { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(check))
                    .font(.system(size: 13))
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
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
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
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.ink)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.inkForeground)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Board")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.needsYouCount > 0 {
                    TagLabel(title: String(localized: "\(model.needsYouCount) needs you"), style: .warning)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
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
}
