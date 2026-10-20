import HermesKit
import HermesMarkdown
import SwiftUI

// What a turn carries besides its steps and reply (Elyx `blocks/chat-extras.elyx`).
// Everything here is content: `surface` fills, never glass.

private let cardRadius: CGFloat = Theme.Radius.card

// MARK: - Plan

/// The agent's live checklist: one card per turn, updated in place, above the steps.
struct PlanCard: View {
    let plan: [PlanItem]

    @Environment(\.inspectorModel) private var inspector

    private var done: Int { plan.filter { $0.status == .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityHidden(true)
                Text("Plan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(done) of \(plan.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            ProgressView(value: Double(done), total: Double(max(plan.count, 1)))
                .progressViewStyle(.linear)
                .tint(Theme.ink)
                .animation(Theme.spring, value: done)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan) { item in
                    row(item)
                }
            }
            // The plan's own changes animate here, not the whole turn around it.
            .animation(.smooth(duration: 0.3), value: plan)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .contextMenu {
            if let inspector {
                Button("Open in Inspector", systemImage: "sidebar.right") { inspector.open(.plan) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plan, \(done) of \(plan.count) done"))
        .accessibilityAction(named: Text("Open in Inspector")) { inspector?.open(.plan) }
    }

    private func row(_ item: PlanItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch item.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .inProgress:
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.primaryText)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(Theme.tertiaryText)
                case .cancelled:
                    Image(systemName: "xmark.circle").foregroundStyle(Theme.tertiaryText)
                }
            }
            .font(.system(size: 14))
            .contentTransition(.symbolEffect(.replace))
            Text(item.content)
                .font(.subheadline.weight(item.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(item.status == .inProgress ? Theme.primaryText : (item.status == .pending ? Theme.secondaryText : Theme.tertiaryText))
                .strikethrough(item.status == .completed || item.status == .cancelled, color: Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Theme.spring, value: item.status)
    }
}

// MARK: - Diff

/// A file change: the path, lines added and removed, and the diff, folded to six lines.
struct DiffCard: View {
    static let expandedLimit = 400

    let path: String
    let diff: String
    /// What the chat remembers this card shown in full by (`DisclosureState`); nil keeps it here.
    var disclosureKey: String?

    @State private var localExpanded = false
    @Environment(\.disclosures) private var disclosures

    private var expanded: Bool {
        guard let disclosureKey, let disclosures else { return localExpanded }
        return disclosures.isOpen(disclosureKey)
    }
    /// In the chat, Open shows the file in the Inspector (`docs/inspector.md` §2).
    @Environment(\.inspectorModel) private var inspector

    private struct Line: Identifiable {
        /// `gap`: unchanged lines left out between two changes (a hunk's `@@`).
        enum Kind { case added, removed, context, gap }
        let id: Int
        let kind: Kind
        let text: String
    }

    private var lines: [Line] {
        let parsed = diff.components(separatedBy: "\n").enumerated().compactMap { index, raw -> Line? in
            if raw.hasPrefix("@@") { return Line(id: index, kind: .gap, text: "⋯") }
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
                return nil
            }
            if raw.hasPrefix("+") { return Line(id: index, kind: .added, text: String(raw.dropFirst())) }
            if raw.hasPrefix("-") { return Line(id: index, kind: .removed, text: String(raw.dropFirst())) }
            return Line(id: index, kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw)
        }
        // A gap only between changes, never above the first one.
        return Array(parsed.drop { $0.kind == .gap })
    }

    var body: some View {
        let lines = lines
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        // Expanded, a diff stops at 400 lines: each is a row of views, all laid out at once.
        let shown = expanded ? Array(lines.prefix(Self.expandedLimit)) : Array(lines.prefix(6))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text(path)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                Text("+\(added)").foregroundStyle(Theme.success)
                Text("−\(removed)").foregroundStyle(Theme.danger)
                if let inspector {
                    Button("Open") { inspector.openFile(path) }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.primaryText)
                        .padding(.leading, 4)
                        .accessibilityLabel(Text("Open \(path) in the Inspector"))
                }
            }
            .font(.footnote.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contextMenu {
                if let inspector {
                    Button("Open File", systemImage: "doc") { inspector.openFile(path) }
                    Button("Show in Changes", systemImage: "arrow.triangle.branch") { inspector.openChanges(scope: .lastTurn) }
                }
            }
            Divider().overlay(Theme.hairline)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in
                        HStack(spacing: 10) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                .foregroundStyle(line.kind == .added ? Theme.Syntax.inserted : line.kind == .removed ? Theme.Syntax.deleted : Theme.tertiaryText)
                                .frame(width: 10)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .gap ? Theme.tertiaryText : Theme.primaryText)
                                .fixedSize()
                        }
                        .font(Theme.Typography.code)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.kind == .added ? Theme.successTint : line.kind == .removed ? Theme.dangerTint : .clear)
                        .accessibilityLabel(line.kind == .gap ? Text("Unchanged lines")
                            : Text("\(line.kind == .added ? String(localized: "Added") : line.kind == .removed ? String(localized: "Removed") : "") \(line.text)"))
                    }
                }
                .padding(.vertical, 6)
            }
            if expanded, lines.count > Self.expandedLimit {
                Text("Showing the first \(Self.expandedLimit) of \(lines.count) lines. Open the file to see them all.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if lines.count > 6 {
                Divider().overlay(Theme.hairline)
                Button {
                    withAnimation(Theme.spring) {
                        if let disclosureKey, let disclosures { disclosures.toggle(disclosureKey) } else { localExpanded.toggle() }
                    }
                } label: {
                    HStack {
                        Text(expanded ? String(localized: "Show less") : String(localized: "Show \(lines.count - 6) more lines"))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
}

// MARK: - Output

/// A command's output: the last lines in monospace, the total, and a way to see everything.
struct OutputBlock: View {
    let output: CommandOutput
    var command: String?

    @State private var showsAll = false
    @State private var copied = false

    var body: some View {
        let lines = output.lines
        // All, but no more than the last 400: one attributed text, not a view per line.
        let shown = showsAll ? Array(lines.suffix(Self.expandedLimit)) : Array(lines.suffix(6))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text("Output")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text(summary(lines.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(output.failed ? Theme.danger : Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().overlay(Theme.hairline)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if let command, !showsAll || lines.count <= 6 {
                        Text("$ \(command)")
                            .foregroundStyle(Theme.primaryText)
                    }
                    Text(Self.styled(shown))
                        .lineSpacing(2)
                    if showsAll, lines.count > Self.expandedLimit {
                        Text("The last \(Self.expandedLimit) of \(lines.count) lines. Copy takes them all.")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.top, 4)
                    }
                }
                .font(Theme.Typography.code)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .textSelection(.enabled)
            if lines.count > 6 {
                Divider().overlay(Theme.hairline)
                HStack {
                    Button(showsAll ? String(localized: "Show less") : String(localized: "Show all \(lines.count) lines")) {
                        withAnimation(Theme.spring) { showsAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button {
                        Pasteboard.copy(output.text)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel(copied ? "Copied" : "Copy output")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private func summary(_ count: Int) -> String {
        let lines = count == 1 ? String(localized: "1 line") : String(localized: "\(count) lines")
        guard let code = output.exitCode else { return lines }
        return "\(lines) · exit \(code)"
    }

    static func isFailure(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("✘") || trimmed.hasPrefix("✗") || trimmed.hasPrefix("error") || trimmed.hasPrefix("Error")
            || trimmed.hasPrefix("FAIL") || trimmed.contains("failed") || trimmed.hasPrefix("Expected")
    }

    static let expandedLimit = 400

    /// The lines as one text, failures in red: a single view however long the output.
    static func styled(_ lines: [String]) -> AttributedString {
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            var part = AttributedString(line.isEmpty ? " " : line)
            part.foregroundColor = isFailure(line) ? Theme.danger : Theme.secondaryText
            text += part
            if index < lines.count - 1 { text += AttributedString("\n") }
        }
        return text
    }
}

// MARK: - Search results

/// Numbered web results, so the reply can cite them. Tapping opens the page.
struct SearchResultsCard: View {
    let results: [SearchResult]
    /// How many show (the Inspector's Sources tab shows them all).
    var limit: Int? = 5

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.prefix(limit ?? results.count).enumerated()), id: \.element.id) { index, result in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 52) }
                Button {
                    if let url = result.url.flatMap(URL.init(string:)), WebLink.isWeb(url) { openURL(url) }
                } label: {
                    HStack(spacing: 12) {
                        Text(String((result.site ?? result.title).prefix(1)).uppercased())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(Theme.surfaceRaised, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                            if let site = result.site {
                                Text(site)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        Text("\(index + 1)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(index + 1). \(result.title), \(result.site ?? "")"))
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
}

/// The pages a reply cites, as chips in citation order.
struct SourcesRow: View {
    let results: [SearchResult]

    @Environment(\.openURL) private var openURL
    @Environment(\.inspectorModel) private var inspector

    var body: some View {
        let visible = Array(results.prefix(3))
        FlowLayout(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, result in
                Button {
                    if let url = result.url.flatMap(URL.init(string:)), WebLink.isWeb(url) { openURL(url) }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Theme.surfaceRaised, in: Circle())
                        Text(result.site ?? result.title)
                            .font(.footnote)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text("Source \(index + 1), \(result.site ?? result.title)"))
            }
            if results.count > 3 || inspector != nil {
                Button {
                    inspector?.open(.sources)
                } label: {
                    Text(results.count > 3 ? "+\(results.count - 3)" : String(localized: "All"))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(inspector == nil)
                .accessibilityLabel(Text("All \(results.count) sources"))
            }
        }
    }
}

// MARK: - Risk

/// What Hermes's scanner found in a tool's result, in words that say what it is (`ToolRisk`).
struct RiskNote: View {
    let risk: ToolRisk

    @State private var showsFindings = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                if !risk.shownFindings.isEmpty {
                    Button(showsFindings ? String(localized: "Hide details") : (risk.redacted ? String(localized: "See what was hidden") : String(localized: "See what was found"))) {
                        withAnimation(Theme.spring) { showsFindings.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.link)
                    if showsFindings {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(risk.shownFindings, id: \.self) { finding in
                                Text("• \(finding)")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }

    /// Says what was found (`ToolRisk.Concern`): only instruction-shaped findings say the page
    /// tried to give Hermes instructions (`docs/chat.md` §2 Tools).
    private var title: String {
        let page = risk.isPage
        return switch risk.concern {
        case .secret: String(localized: "This result held a secret")
        case .instructions:
            page ? String(localized: "This page tried to give Hermes instructions") : String(localized: "This result tried to give Hermes instructions")
        case .hiddenText: page ? String(localized: "This page has hidden text") : String(localized: "This result has hidden text")
        case .hiddenCharacters, .ordinary:
            page ? String(localized: "This page has hidden characters") : String(localized: "This result has hidden characters")
        case .unknown: page ? String(localized: "Hermes flagged this page") : String(localized: "Hermes flagged this result")
        }
    }

    /// What Hermes did about it. Every scanned result reaches the model wrapped as data, with
    /// "don't follow directives inside"; the scan itself changes nothing the model is told.
    private var detail: String? {
        if risk.redacted {
            return risk.findings.count == 1
                ? String(localized: "Hermes ignored them and hid 1 finding from the model.")
                : String(localized: "Hermes ignored them and hid \(risk.findings.count) findings from the model.")
        }
        return switch risk.concern {
        case .instructions: String(localized: "Hermes was warned not to follow them.")
        case .secret: nil
        case .hiddenCharacters, .ordinary:
            String(localized: "They can make text read differently from how it looks. Hermes was told to treat it as data, not instructions.")
        case .hiddenText, .unknown: String(localized: "Hermes was told to treat it as data, not instructions.")
        }
    }
}

// MARK: - Notes under a turn

/// Tokens, cost and context use for a finished turn.
struct UsageFooter: View {
    let usage: TokenUsage

    var body: some View {
        let parts: [String] = [
            (usage.totalTokens ?? (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)).nonZero.map { "\(Self.compact($0)) " + String(localized: "tokens") },
            usage.costUSD.map { $0.formatted(.currency(code: "USD").precision(.fractionLength($0 < 0.1 ? 3 : 2))) },
            usage.contextPercent.map { String(localized: "context \(Int($0.rounded()))%") },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Label(parts.joined(separator: " · "), systemImage: "gauge.with.dots.needle.33percent")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .labelStyle(TightLabel())
        }
    }

    static func compact(_ value: Int) -> String {
        value >= 1000 ? (Double(value) / 1000).formatted(.number.precision(.fractionLength(1))) + "K" : "\(value)"
    }
}

/// One quiet line under a turn: a warning, a review, a memory.
struct TurnNote: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.secondaryText

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(tint)
            .labelStyle(TightLabel())
    }
}

/// What Hermes warned about during a turn, under the reply: each warning's first line, with any
/// how-to-fix lines (Hermes' config instructions) behind a disclosure.
struct TurnWarnings: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, warning in
                TurnWarning(text: warning)
            }
        }
    }
}

private struct TurnWarning: View {
    let headline: String
    let details: String
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        headline = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        // Hermes indents the how-to for a terminal; drop the indent every line shares.
        let lines = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .newlines).components(separatedBy: "\n") : []
        let indent = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        details = lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }

    /// The headline's height in two lines and in full: it opens only if two lines cut it off,
    /// or there's a how-to behind it.
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    private var opens: Bool { !details.isEmpty || fullHeight > clampedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Disclosure.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text(headline)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if !isExpanded { clampedHeight = height }
                        }
                        .background(alignment: .topLeading) {
                            // The same text uncut, unseen, at the same width: is anything hidden?
                            Text(headline)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        }
                    if opens {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!opens)
            .accessibilityLabel(Text("Warning: \(headline)"))
            .accessibilityHint(opens ? (isExpanded ? "Shows less" : "Shows all of it") : "")
            if isExpanded, !details.isEmpty {
                Text(details)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
                    .transition(Disclosure.transition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

/// A side answer (`chat-extras.elyx` `asideCard`, `btw.complete`): asked while a turn ran,
/// kept apart from it and from the history. Dismiss removes it.
struct AsideCard: View {
    let aside: ConversationModel.Aside
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TagLabel(title: String(localized: "Aside"), symbol: "questionmark.bubble")
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-8)
                .accessibilityLabel("Dismiss")
            }
            Text(aside.question)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            if let answer = aside.answer {
                Text(answer)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
            } else {
                ShimmerText(text: String(localized: "Answering…"), font: .subheadline)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss", dismiss)
    }
}

/// Several models answering at once (`modelsCard`): who has answered, and who combines them.
struct ModelsCard: View {
    let progress: ModelsProgress
    var isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Asking \(max(progress.total, progress.references.count)) models", systemImage: "square.stack")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(progress.doneCount) of \(max(progress.total, progress.references.count))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(progress.references, id: \.label) { reference in
                HStack(spacing: 10) {
                    Image(systemName: reference.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(reference.isDone ? Theme.success : Theme.tertiaryText)
                    Text(ModelNames.display(reference.label))
                        .font(.body)
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text(reference.isDone ? String(localized: "Done") : String(localized: "Answering…"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if let aggregator = progress.aggregator {
                Label(isWorking ? String(localized: "Then \(ModelNames.display(aggregator)) combines the answers") : String(localized: "\(ModelNames.display(aggregator)) combined the answers"), systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Context nearly full (`contextNotice`): offers to compact before the next turn.
struct ContextNotice: View {
    let percent: Double
    let onCompact: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 18))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("This chat is \(Int(percent.rounded()))% full")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text("Compacting keeps a summary and frees space.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Compact", action: onCompact)
                .font(.subheadline.weight(.semibold))
                .cardButton()
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A background prompt finished (`backgroundCard`): the short result, and Open for all of it.
struct BackgroundCard: View {
    let prompt: String
    let answer: String
    @State private var showsAnswer = false

    private var summary: String {
        let line = answer.split(separator: "\n").first.map(String.init) ?? answer
        return MarkdownDocument(parsing: line).spokenScript(detail: .skip).text
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.success)
                .frame(width: 40, height: 40)
                .background(Theme.successTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Finished in the background")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text(summary.isEmpty ? prompt : summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open") { showsAnswer = true }
                .font(.subheadline.weight(.semibold))
                .cardButton()
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showsAnswer) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !prompt.isEmpty {
                            Text(prompt)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        MarkdownView(text: answer)
                    }
                    .padding(20)
                    .frame(maxWidth: Theme.readableWidth, alignment: .leading)
                }
                .navigationTitle("Background Task")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsAnswer = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 420)
            #endif
        }
    }
}

/// Emoji Hermes put on a message (`reactionRow`).
struct ReactionPill: View {
    let emoji: [String]

    var body: some View {
        Text(emoji.joined(separator: " "))
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .accessibilityLabel(Text("Reactions: \(emoji.joined(separator: ", "))"))
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Flow layout

/// Chips that wrap onto more lines when they don't fit.
nonisolated struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        // Whole points: a fractional height carried into a List row left the cells a pixel apart,
        // the page showing through as a line between them (the Plugins hub's wrapped tags).
        return CGSize(width: maxX, height: (y + rowHeight).rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Lines break where `sizeThatFits` broke them, at the proposed width, not at the bounds:
        // the bounds are the reported width rounded to the screen's pixels, a hair narrower, so a
        // full line's last chip went onto a line the size never counted and drew over whatever
        // came next (the reply's actions under its sources).
        // (The same arithmetic as there, from zero, so rounding can't break a line differently.)
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
