import HermesKit
import SwiftUI

// The Status family (`widgets/status.elyx`): status, steps, alert.

// MARK: - status

/// The health of one thing (a hero with its numbers and the one thing to fix) or many (a matrix,
/// problems first) (`Status.status`, `statusMatrix`, `statusDeploy`).
struct StatusBody: View {
    let model: StatusWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Problems first: critical, warning, unverified, stale, pending, info, ok; payload order within.
    private var sorted: [StatusWidget.Item] {
        model.items.enumerated().sorted { lhs, rhs in
            let left = Self.rank(lhs.element.state), right = Self.rank(rhs.element.state)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    static func rank(_ state: WidgetItemState) -> Int {
        switch state {
        case .critical: 0
        case .warning: 1
        case .unverified: 2
        case .stale: 3
        case .pending: 4
        case .info: 5
        case .ok: 6
        }
    }

    var body: some View {
        switch model.layout == .auto ? (model.items.count == 1 ? .hero : .matrix) : model.layout {
        case .compact: compact(model.items[0])
        case .hero: hero(model.items[0])
        default: matrix
        }
    }

    private func headline(_ item: StatusWidget.Item) -> String {
        item.headline ?? Self.defaultHeadline(item.state)
    }

    /// "Since 06:00" today, "Since Sat 17 Oct" before; never the raw timestamp.
    private func since(_ item: StatusWidget.Item) -> String? {
        guard let raw = item.since, let (date, _) = WidgetFormatter.parse(raw) else { return nil }
        let when = Calendar.current.isDate(date, inSameDayAs: context.now) ? formatter.time(raw) : formatter.date(raw)
        return when.map { String(localized: "Since \($0)") }
    }

    static func defaultHeadline(_ state: WidgetItemState) -> String {
        switch state {
        case .ok: String(localized: "Healthy")
        case .info: String(localized: "Note")
        case .warning: String(localized: "Needs attention")
        case .critical: String(localized: "Down")
        case .unverified: String(localized: "Not checked")
        case .stale: String(localized: "No recent report")
        case .pending: String(localized: "Checking")
        }
    }

    private func compact(_ item: StatusWidget.Item) -> some View {
        let tone = WidgetTone(item.state)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.symbol).foregroundStyle(tone == .unverified ? Theme.primaryText : tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(item)).font(WidgetFont.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(widgetLinking: detail).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func hero(_ item: StatusWidget.Item) -> some View {
        let tone = WidgetTone(item.state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: tone.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone == .unverified ? Theme.primaryText : tone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(item)).font(WidgetFont.valueSmall)
                    if let detail = item.detail {
                        Text(widgetLinking: detail).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                    if let since = since(item) { Text(since).font(WidgetFont.caption).foregroundStyle(Theme.tertiaryText) }
                }
            }
            .accessibilityElement(children: .combine)
            if let evidence = item.evidence { EvidenceLine(evidence: evidence) }
            if let metrics = item.metrics, !metrics.isEmpty {
                let columns = typeSize.isAccessibilitySize ? 2 : min(metrics.count, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 8) {
                    ForEach(Array(metrics.prefix(4).enumerated()), id: \.offset) { _, metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.label).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                            Text(formatter.string(metric.value))
                                .font(WidgetFont.valueSmall.monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel([metric.label, formatter.string(metric.value), metric.state.flatMap { WidgetTone($0) < .info ? WidgetTone($0).word : nil }].compactMap { $0 }.joined(separator: ", "))
                    }
                }
                .widgetWell()
            }
            if let fix = item.fix {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 12, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One thing to fix").font(WidgetFont.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        Text(fix).font(WidgetFont.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tone.tint, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if let actions = item.actions, !actions.isEmpty { RowActions(actions: actions, item: (item.id, item.name), context: context) }
        }
    }

    /// `Status.statusMatrix`: "4 of 6 healthy", then the items in pairs of equal height.
    private var matrix: some View {
        let items = context.view.showsAll ? sorted : Array(sorted.prefix(8))
        let healthy = model.items.filter { $0.state == .ok || $0.state == .info }.count
        let unchecked = model.items.filter { $0.state == .unverified }.count
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(healthy) of \(model.items.count)").font(WidgetFont.valueSmall.monospacedDigit())
                Text(unchecked > 0 ? String(localized: "healthy · \(unchecked) not checked") : String(localized: "healthy"))
                    .font(WidgetFont.label)
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row, id: \.id) { item in cell(item) }
                        if row.count < perRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
            if model.items.count > 8 {
                ShowAllButton(total: model.items.count, isExpanded: context.view.showsAll) { context.updateView { $0.showsAll.toggle() } }
            }
        }
    }

    private func cell(_ item: StatusWidget.Item) -> some View {
        let tone = WidgetTone(item.state)
        let content = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: tone.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone == .unverified ? Theme.primaryText : tone.color)
                Text(item.name).font(WidgetFont.body.weight(.semibold)).lineLimit(1)
                if item.actions?.isEmpty == false {
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                }
            }
            // What's going on, in the state's colour for a problem (`statusMatrix`); how it's known is
            // in VoiceOver and the item's menu.
            Text(widgetLinking: item.detail ?? headline(item))
                .font(WidgetFont.caption)
                .foregroundStyle(tone < .info && tone != .unverified ? tone.color : Theme.secondaryText)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
        .overlay {
            if tone.isDashed {
                RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous)
                    .strokeBorder(Theme.primaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.name, tone.word, item.detail ?? item.headline, since(item), item.evidence.map { $0.kind == .claim ? String(localized: "Said by \($0.label)") : $0.label }]
            .compactMap { $0 }.joined(separator: ", "))
        .rowActions(item.actions, item: (item.id, item.name), context: context)
        return Group {
            if let actions = item.actions, !actions.isEmpty {
                Menu {
                    ForEach(actions, id: \.id) { action in
                        Button(action.label) { context.perform(action, item: (item.id, item.name)) }
                    }
                } label: { content }
                .menuStyle(.button)
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }
}

// MARK: - steps

/// Progress through ordered stages, with durations and a result line (`Status.steps`,
/// `stepsPipeline`, `stepsCompact`). The client never advances a step by itself.
struct StepsBody: View {
    let model: StepsWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.kind {
            case .pipeline where !typeSize.isAccessibilitySize && model.steps.allSatisfy { $0.title.count <= 16 }:
                pipeline
            case .compact:
                compact
            default:
                vertical
            }
            if let result = model.result { resultLine(result) }
            if let started = model.startedAt.flatMap({ formatter.time($0) }) {
                Text([String(localized: "Started \(started)"), context.payload.envelope.producer.map { String(localized: "by \($0.name)") }].compactMap { $0 }.joined(separator: " "))
                    .font(WidgetFont.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private var vertical: some View {
        let doneCount = model.steps.prefix { $0.state == .done }.count
        let foldsDone = model.steps.count > 8 && doneCount > 1 && !context.view.showsAll
        let shown = foldsDone ? Array(model.steps.dropFirst(doneCount)) : model.steps
        return VStack(alignment: .leading, spacing: 0) {
            if foldsDone {
                Button {
                    context.updateView { $0.showsAll = true }
                } label: {
                    Label(String(localized: "\(doneCount) steps done"), systemImage: "checkmark.circle.fill")
                        .font(WidgetFont.label)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                row(step, number: (foldsDone ? doneCount : 0) + index + 1, isLast: index == shown.count - 1)
            }
        }
    }

    private func row(_ step: StepsWidget.Step, number: Int, isLast: Bool) -> some View {
        let progress = WidgetProgress(rawValue: step.state.rawValue) ?? .unknown
        let isRunning = step.state == .running
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                StepGlyph(progress: progress).frame(width: 18, height: 20)
                if !isLast { Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.title)
                        .font(isRunning ? WidgetFont.body.weight(.semibold) : WidgetFont.body)
                        .foregroundStyle(step.state == .skipped ? Theme.secondaryText : Theme.primaryText)
                    Spacer(minLength: 6)
                    if let duration = step.duration, !typeSize.isAccessibilitySize {
                        Text(formatter.duration(duration)).font(WidgetFont.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                }
                if isRunning, let fraction = step.progress {
                    WidgetBar(fraction: fraction, height: 4)
                        .animation(.smooth(duration: 0.4), value: fraction)
                }
                if let detail = runningDetail(step) {
                    Text(widgetLinking: detail)
                        .font(WidgetFont.caption)
                        .foregroundStyle(step.state == .failed ? Theme.danger : step.state == .blocked ? Theme.warning : Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let duration = step.duration, typeSize.isAccessibilitySize {
                    Text(formatter.duration(duration)).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
                if let evidence = step.evidence { EvidenceLine(evidence: evidence) }
                if let actions = step.actions, !actions.isEmpty { RowActions(actions: actions, item: (step.id, step.title), context: context) }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(step, number: number))
    }

    private func runningDetail(_ step: StepsWidget.Step) -> String? {
        if step.state == .running, let staleAt = WidgetClock.staleAt(context.payload.envelope), context.now >= staleAt,
           let asOf = WidgetClock.date(context.payload.envelope.asOf) {
            return String(localized: "No update for \(formatter.duration(context.now.timeIntervalSince(asOf)))")
        }
        var parts: [String] = []
        if step.state == .running, let fraction = step.progress { parts.append(formatter.percent(fraction, precision: 0)) }
        if let detail = step.detail { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func spoken(_ step: StepsWidget.Step, number: Int) -> String {
        let progress = WidgetProgress(rawValue: step.state.rawValue) ?? .unknown
        var parts = [String(localized: "Step \(number)"), step.title]
        switch step.state {
        case .done: parts.append(step.duration.map { String(localized: "done in \(formatter.duration($0))") } ?? progress.word)
        case .unknown: parts.append(String(localized: "outcome not known"))
        default: parts.append(progress.word)
        }
        if step.state == .running, let fraction = step.progress { parts.append(formatter.percent(fraction, precision: 0)) }
        if let detail = step.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    private var pipeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                    }
                    let progress = WidgetProgress(rawValue: step.state.rawValue) ?? .unknown
                    HStack(spacing: 5) {
                        StepGlyph(progress: progress)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(step.title).font(WidgetFont.label.weight(.medium))
                            Text(step.duration.map { formatter.duration($0) } ?? progress.word.lowercased())
                                .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(step.state == .failed ? Theme.dangerTint : Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                    .overlay {
                        if step.state == .running {
                            RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.2)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(step, number: index + 1))
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var compact: some View {
        let current = model.steps.first { $0.state == .running || $0.state == .failed || $0.state == .blocked } ?? model.steps.last
        return VStack(alignment: .leading, spacing: 6) {
            // "Step 3 of 5" is the header's meta.
            Text(current?.title ?? "").font(WidgetFont.body.weight(.semibold))
            HStack(spacing: 3) {
                ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                    Capsule()
                        .fill(segmentColor(step.state))
                        .overlay {
                            if step.state == .unknown {
                                Capsule().strokeBorder(Theme.primaryText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            }
                        }
                        .frame(height: 5)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func segmentColor(_ state: StepsWidget.Step.State) -> Color {
        switch state {
        case .done, .running: Theme.ink
        case .failed: Theme.danger
        case .blocked: Theme.warning
        case .unknown: .clear
        case .waiting, .skipped: Theme.controlFill
        }
    }

    private func resultLine(_ result: StepsWidget.Outcome) -> some View {
        let tone: WidgetTone = switch result.state {
        case .ok: .ok
        case .info: .info
        case .warning: .warning
        case .critical: .critical
        case .unverified: .unverified
        }
        return VStack(alignment: .leading, spacing: 4) {
            Label(result.text, systemImage: tone.symbol)
                .font(WidgetFont.label.weight(.medium))
                .foregroundStyle(tone == .unverified ? Theme.primaryText : tone.color)
            if let detail = result.detail {
                Text(widgetLinking: detail)
                    .font(result.detailStyle == .code ? WidgetFont.mono : WidgetFont.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A step's state: a glyph with its own shape (circle, half, tick, cross, dashed question mark).
private struct StepGlyph: View {
    let progress: WidgetProgress

    var body: some View {
        Group {
            if progress == .running {
                Image(systemName: "circle.lefthalf.filled")
            } else if progress == .unknown {
                Image(systemName: "questionmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Theme.primaryText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
            } else {
                Image(systemName: progress.symbol)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(progress.color)
        .accessibilityHidden(true)
    }
}

// MARK: - alert

/// Something that must not be missed, as a tinted card with what happened and what to do first
/// (`Status.alert`, `alertIncident`, `alertInfo`). The card's tint comes from `WidgetCard`.
struct AlertBody: View {
    let model: AlertWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.headline)
                .font(hasFacts ? WidgetFont.body.weight(.semibold) : WidgetFont.body)
                .fixedSize(horizontal: false, vertical: true)
            if hasFacts { facts }
            if let timeline = model.timeline, !timeline.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(timeline.suffix(5).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatter.time(line.at) ?? "").font(WidgetFont.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                            Text(widgetLinking: line.text).font(WidgetFont.label).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let next = model.next {
                // Small, with the arrow in the alert's colour (`Status.alert`).
                Label {
                    Text(String(localized: "Next: \(next)")).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.right").foregroundStyle(model.severity == .critical ? Theme.danger : model.severity == .warning ? Theme.warning : Theme.info)
                }
                    .font(WidgetFont.label.weight(.medium))
            }
            if let acknowledged = model.acknowledged {
                Text(String(localized: "Acknowledged by \(acknowledged.by) · \(formatter.time(acknowledged.at) ?? acknowledged.at)"))
                    .font(WidgetFont.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            if let evidence = model.evidence { EvidenceLine(evidence: evidence) }
        }
        .onAppear {
            // A new critical alert in view is announced once; its updates aren't.
            if model.severity == .critical, model.status != .resolved, voiceOver {
                AccessibilityNotification.Announcement(String(localized: "Critical: \(context.payload.title)")).post()
            }
        }
    }

    private var hasFacts: Bool { model.impact != nil || model.startedAt != nil || model.status != nil }

    private var factItems: [(label: String, value: String)] {
        var items: [(label: String, value: String)] = []
        if let impact = model.impact { items.append((String(localized: "Impact"), impact)) }
        if let started = model.startedAt, let date = WidgetClock.date(started) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            items.append((String(localized: "Started"), formatter.localizedString(for: date, relativeTo: context.now)))
        }
        if let status = model.status { items.append((String(localized: "Status"), status.word)) }
        return items
    }

    /// Impact, started and status side by side, label over value (`Status.alertIncident`); one
    /// under another at accessibility sizes.
    private var facts: some View {
        let layout = factsStacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            ForEach(Array(factItems.enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                    Text(fact.value).font(WidgetFont.body.weight(.medium)).foregroundStyle(Theme.primaryText)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .widgetWell()
    }

    private var factsStacked: Bool { typeSize.isAccessibilitySize }
}

private extension AlertWidget.Status {
    var word: String {
        switch self {
        case .investigating: String(localized: "Investigating")
        case .identified: String(localized: "Identified")
        case .monitoring: String(localized: "Monitoring")
        case .resolved: String(localized: "Resolved")
        }
    }
}
