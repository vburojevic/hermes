import HermesKit
import SwiftUI

/// `compactionDivider` (`docs/chat.md` §2a): where Hermes compacted the chat, a quiet divider in
/// place of its handoff summary, which nobody wrote, with the time it did. Folded by default; it
/// opens to the summary's own words as plain text, read-only, without Hermes's instructions to
/// the model.
struct CompactionDivider: View {
    let summary: String
    /// When Hermes compacted the chat: the summary's stored time.
    var date: Date?

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.compress.vertical")
                            .accessibilityHidden(true)
                        Text(line)
                        Image(systemName: "chevron.right")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Earlier messages summarized")
            .accessibilityValue(isOpen ? Text("Shown") : Text("Hidden"))
            .accessibilityHint(isOpen ? "Hides the summary" : "Shows the summary")
            .accessibilityIdentifier("compactionDivider")

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hermes keeps this summary in place of the earlier messages. It can't be edited.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    // Plain text: a handoff for the model, not a reply to render.
                    Text(verbatim: CompactionSummary.plainText(summary))
                        .font(Theme.Typography.compactMessage)
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    /// "Earlier messages were summarized · 14:02".
    private var line: String {
        guard let date else { return String(localized: "Earlier messages were summarized") }
        return String(localized: "Earlier messages were summarized · \(date.formatted(date: .omitted, time: .shortened))")
    }
}

/// The line over a reply to a delivery or another Bot (`deliveryReplyCaption`, `docs/chat.md`
/// §2a): the Bot answered the routine, the automation or that Bot, not the person.
struct DeliveryReplyCaption: View {
    let answering: Answering
    /// Names a Bot as the app does.
    var botName: (String) -> String? = { _ in nil }

    private var text: String {
        switch answering {
        case .delivery(.routine(let name)): String(localized: "Replying to the routine \(name)")
        case .delivery(.webhook(let name)): String(localized: "Replying to the webhook \(name)")
        case .delivery(.automation): String(localized: "Replying to an automated message")
        case .bot(let sender): String(localized: "Replying to \(botName(sender.handle) ?? sender.name)")
        }
    }

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: "arrowshape.turn.up.left")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.tertiaryText)
        .accessibilityElement(children: .combine)
    }
}

/// Finished work (`finishedNotice`, `docs/chat.md` §2a): background processes or helpers that
/// finished, as one quiet line in the transcript's column saying what ran, how it went and how
/// long it took ("Tests failed · exit 1 · 40 s", "Engineer replied · 4 min"). Processes in a row
/// are one line, "4 background tasks finished · 3 ok, 1 failed", that opens to a row each
/// (`finishedProcessRow`). A failure is the warning glyph and its words in the danger colour, never
/// a red slab. A single process opens to its command and output; helpers to their results.
struct FinishedWorkRow: View {
    let notice: Notice
    /// Names a profile as the app does ("Engineer").
    var botName: (String) -> String? = { _ in nil }
    /// The gateway's list, which knows when a process really started and exited.
    var listed: (String) -> BackgroundProcess? = { _ in nil }
    /// The row of the turn whose step started a process, to show it.
    var stepRow: (String) -> String? = { _ in nil }
    var showRow: (String) -> Void = { _ in }

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The line's size: the footnote on iPhone and iPad, 13 pt on the Mac, where the footnote is
    /// too small to read in a transcript.
    static var lineFont: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .footnote
        #endif
    }

    private var work: [FinishedWork] {
        notice.work.map { work in
            guard case .process(let process) = work else { return work }
            return .process(process.timed(by: listed(process.id)))
        }
    }

    private var processes: [FinishedProcess] {
        work.compactMap { if case .process(let process) = $0 { process } else { nil } }
    }

    /// Several processes: a row each when open.
    private var isGroup: Bool { processes.count > 1 && processes.count == work.count }

    private var summary: FinishedSummary {
        Notice.finishedSummary(work, botName: botName) ?? FinishedSummary(head: notice.text)
    }

    private var failed: Bool {
        work.contains { work in
            switch work {
            case .process(let process): process.isFailure
            case .helper(let helper): !helper.succeeded
            }
        }
    }

    /// The line's glyph: the warning triangle when anything failed, else what it is.
    private var glyph: (symbol: String, color: Color) {
        if failed { return ("exclamationmark.triangle.fill", Theme.danger) }
        if case .helper? = work.first { return ("person.2", Theme.tertiaryText) }
        if processes.allSatisfy({ $0.recipient != nil }) { return ("bubble.left.and.text.bubble.right", Theme.tertiaryText) }
        if processes.count == 1, let only = processes.first { return Self.glyph(only) ?? ("terminal", Theme.tertiaryText) }
        if processes.allSatisfy({ $0.outcome == .succeeded }) { return ("checkmark.circle.fill", Theme.success) }
        return ("terminal", Theme.tertiaryText)
    }

    /// What happened in the secondary colour, its facts in the tertiary, "1 failed" in the danger.
    private var styledLine: AttributedString {
        var line = AttributedString(summary.head)
        line.foregroundColor = Theme.secondaryText
        line.font = Self.lineFont.weight(.medium)
        guard !summary.parts.isEmpty else { return line }
        var dot = AttributedString(" · ")
        dot.foregroundColor = Theme.tertiaryText
        line += dot
        for (index, part) in summary.parts.enumerated() {
            var words = AttributedString(part.text + (index < summary.parts.count - 1 ? summary.separator : ""))
            words.foregroundColor = part.isFailure ? Theme.danger : Theme.tertiaryText
            if part.isFailure { words.font = Self.lineFont.weight(.medium) }
            line += words
        }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: glyph.symbol)
                        .font(Self.lineFont)
                        .foregroundStyle(glyph.color)
                        .accessibilityHidden(true)
                    Text(styledLine)
                        .font(Self.lineFont)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary.text)
            .accessibilityValue(isOpen ? Text("Shown") : Text("Hidden"))
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
            .accessibilityIdentifier("finishedNotice")

            if isOpen {
                Group {
                    if isGroup {
                        VStack(alignment: .leading, spacing: 0) {
                            // By place: Hermes's own fallback id ("unknown") can repeat.
                            ForEach(Array(processes.filter { !$0.isUnlisted }.enumerated()), id: \.offset) { _, process in
                                FinishedProcessRow(process: process, botName: botName, stepRow: stepRow(process.id), showRow: showRow)
                            }
                            let unlisted = processes.filter(\.isUnlisted).count
                            if unlisted > 0 {
                                Text(String(localized: "\(unlisted) more finished. Hermes counted them without details."))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.vertical, 10)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 14)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(work.enumerated()), id: \.offset) { _, work in
                                switch work {
                                case .process(let process): processDetail(process)
                                case .helper(let helper): helperDetail(helper)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `finishedProcessDetail`: how it ended and how long it ran, with a glyph that says it too,
    /// Show Step, the command and the last lines of its output.
    private func processDetail(_ process: FinishedProcess) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let glyph = Self.glyph(process) {
                    Image(systemName: glyph.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(glyph.color)
                        .accessibilityHidden(true)
                }
                Text(process.line(botName: botName))
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(process.isFailure ? Theme.danger : Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let row = stepRow(process.id) {
                    Button("Show Step") { showRow(row) }
                        .font(Theme.Typography.caption.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .accessibilityHint("Shows the step that started it")
                }
            }
            FinishedProcessOutput(process: process)
        }
        .accessibilityElement(children: .contain)
    }

    /// A passed process gets a green check, a failed one the red triangle, a stopped one the grey
    /// square; a pattern it printed, none.
    static func glyph(_ process: FinishedProcess) -> (symbol: String, color: Color)? {
        if process.isFailure { return ("exclamationmark.triangle.fill", Theme.danger) }
        if process.recipient != nil { return ("bubble.left.and.text.bubble.right", Theme.tertiaryText) }
        switch process.outcome {
        case .succeeded: return ("checkmark.circle.fill", Theme.success)
        case .stopped: return ("stop.fill", Theme.tertiaryText)
        default: return nil
        }
    }

    /// `finishedHelperDetail`: the goal in full, what happened when it didn't finish, its result.
    private func helperDetail(_ helper: FinishedHelper) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(helper.goal.isEmpty ? helper.title : helper.goal)
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !helper.succeeded {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text(String(localized: "This helper \(helper.outcomeWord)."))
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.danger)
            }
            if !helper.result.isEmpty {
                ExpandableText(text: helper.result, markdown: true, small: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// `finishedProcessRow`: one process in an open group, as a process step says it: its state
/// glyph, its plain name and "Failed · exit 1 · 40 s" trailing. Tap opens its command, its last
/// lines and Show Step.
struct FinishedProcessRow: View {
    let process: FinishedProcess
    var botName: (String) -> String? = { _ in nil }
    /// The row of the turn whose step started it, when this chat has it.
    var stepRow: String?
    var showRow: (String) -> Void = { _ in }

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The glyph's column, growing with the text beside it.
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if let glyph = FinishedWorkRow.glyph(process) {
                            Image(systemName: glyph.symbol).foregroundStyle(glyph.color)
                        } else {
                            Image(systemName: "terminal").foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .font(FinishedWorkRow.lineFont)
                    .frame(width: glyphWidth)
                    .accessibilityHidden(true)
                    Text(process.name(botName: botName))
                        .font(FinishedWorkRow.lineFont.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(process.status)
                        .font(Theme.Typography.caption.monospacedDigit())
                        .foregroundStyle(process.isFailure ? Theme.danger : Theme.tertiaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(process.spokenStatus(botName: botName))
            .accessibilityValue(isOpen ? Text("Shown") : Text("Hidden"))
            .accessibilityHint(isOpen ? "Hides its output" : "Shows its output")

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    FinishedProcessOutput(process: process)
                    if let stepRow {
                        Button("Show Step") { showRow(stepRow) }
                            .font(Theme.Typography.caption.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ink)
                            .accessibilityHint("Shows the step that started it")
                    }
                }
                .padding(.leading, glyphWidth + 8)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
    }
}

/// What a finished process left: the reply a Bot sent or why it wasn't delivered, else its command
/// and the last 8 lines of its output.
struct FinishedProcessOutput: View {
    let process: FinishedProcess

    var body: some View {
        switch process.answer {
        case .replied(let reply)?:
            ExpandableText(text: reply, markdown: true)
        case .failed(let reason)?:
            Text(reason)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            if !process.command.isEmpty, process.recipient == nil {
                Text(verbatim: "$ " + ProcessNaming.clean(process.command))
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if !process.output.isEmpty {
                let tail = LongText.tail(process.output, lines: 8)
                // Secondary even when it failed: the glyph and the words say so, and the
                // failing lines stay readable as they came.
                Text(verbatim: tail.text)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// Text that shows a few lines, then Show More (`LongText`): what one Bot sent another, a helper's
/// result, a reply carried back. Markdown is rendered with the reply's rules (`docs/chat.md` §3).
struct ExpandableText: View {
    let text: String
    var markdown = false
    var lines = LongText.messageLines
    /// A detail in footnote size (a helper's result in finished work).
    var small = false
    /// Its colour: a message itself (a Bot's card) or a reply carried back reads in the primary
    /// colour, a detail under a line in the secondary.
    var tone: MarkdownView.Tone = .secondary

    @State private var isOpen = false

    private var font: Font { small ? .footnote : Theme.Typography.compactMessage }
    /// A folded line's height, about, at that font.
    private var lineHeight: CGFloat { small ? 17 : 19 }

    var body: some View {
        let long = LongText.isLong(text, lines: lines)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if markdown {
                    MarkdownView(text: text, tone: tone)
                        .environment(\.markdownBodyFont, font)
                } else {
                    Text(linking: text)
                        .font(font)
                        .foregroundStyle(tone == .primary ? Theme.primaryText : Theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            .frame(maxHeight: long && !isOpen ? CGFloat(lines) * lineHeight : nil, alignment: .top)
            .clipped()
            .mask(alignment: .top) {
                if long && !isOpen {
                    LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }
            if long {
                Button(isOpen ? String(localized: "Show Less") : String(localized: "Show More")) { isOpen.toggle() }
                    .font(Theme.Typography.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink)
            }
        }
    }
}

/// A machine-style handoff one Bot wrote another (`handoffBrief`, `HandoffBrief`): one summary
/// line under a "Brief" tag that opens to the whole text.
struct HandoffBriefRow: View {
    let summary: String
    let text: String

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TagLabel(title: String(localized: "Brief"), symbol: "doc.text")
                    Text(summary)
                        .font(Theme.Typography.message)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Brief: \(summary)"))
            .accessibilityValue(isOpen ? Text("Shown") : Text("Hidden"))
            .accessibilityHint(isOpen ? "Hides the whole brief" : "Shows the whole brief")
            if isOpen {
                MarkdownView(text: text, tone: .primary)
                    .environment(\.markdownBodyFont, Theme.Typography.compactMessage)
                    .transition(.opacity)
            }
        }
    }
}
