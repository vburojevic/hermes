import HermesKit
import SwiftUI
import UserNotifications

// The Content and Composition families (`widgets/content.elyx`, `widgets/composition.elyx`):
// summary, guide, compare, handoff, flashcard, stack.

// MARK: - summary

/// The TL;DR with up to five points and the one thing to do first; a news story; a standup
/// (`Content.summary`, `summaryStory`, `summaryStandup`).
struct SummaryBody: View {
    let model: SummaryWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tldr = model.tldr {
                Text(widgetLinking: tldr).font(WidgetFont.valueSmall).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            switch model.kind {
            case .story: if let story = model.story { storyView(story) }
            case .standup: standup
            case .brief: points
            }
            if let doFirst = model.doFirst { doFirstView(doFirst) }
        }
    }

    @ViewBuilder
    private var points: some View {
        let points = model.points ?? []
        if points.isEmpty, model.tldr == nil {
            WidgetEmpty(context: context, fallback: String(localized: "Nothing new."))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        dot(point.state)
                        VStack(alignment: .leading, spacing: 2) {
                            emphasised(point)
                            if let evidence = point.evidence { EvidenceLine(evidence: evidence) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([tone(point.state).flatMap { $0 == .neutral || $0 == .ok ? nil : $0.word }, point.text].compactMap { $0 }.joined(separator: ": "))
                }
            }
        }
    }

    /// The `emphasis` prefix in semibold, the rest regular.
    private func emphasised(_ point: SummaryWidget.Point) -> Text {
        guard let emphasis = point.emphasis, point.text.hasPrefix(emphasis) else { return Text(widgetLinking: point.text).font(WidgetFont.body) }
        let rest = String(point.text.dropFirst(emphasis.count))
        return Text("\(Text(emphasis).fontWeight(.semibold))\(Text(widgetLinking: rest))").font(WidgetFont.body)
    }

    private func tone(_ state: SummaryWidget.Point.State) -> WidgetTone? {
        switch state {
        case .ok: .ok
        case .info: .info
        case .warning: .warning
        case .critical: .critical
        case .unverified: .unverified
        default: .neutral
        }
    }

    @ViewBuilder
    private func dot(_ state: SummaryWidget.Point.State) -> some View {
        let tone = tone(state) ?? .neutral
        if withoutColor, tone != .neutral {
            Image(systemName: tone.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(tone.color)
        } else if tone == .unverified {
            Circle().strokeBorder(Theme.primaryText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])).frame(width: 7, height: 7)
        } else {
            // Grey dots, whatever the point's state (`Content.summary`); VoiceOver says the state.
            Circle().fill(Theme.tertiaryText).frame(width: 6, height: 6)
        }
    }

    private func doFirstView(_ doFirst: SummaryWidget.DoFirst) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Do first").font(WidgetFont.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Text(doFirst.text).font(WidgetFont.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.2))
            .accessibilityElement(children: .combine)
            // Its action is the card's one primary button.
            if let action = doFirst.action {
                Button(action.label) { context.perform(action) }
                    .buttonStyle(WidgetActionButtonStyle(role: .primary, isPending: context.pendingAction == action.id))
                    .disabled(!context.canAnswer && action.kind == .reply)
            }
        }
    }

    private func storyView(_ story: SummaryWidget.Story) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                WidgetTagView(tag: WidgetTag(label: story.status == .confirmed ? String(localized: "Confirmed") : String(localized: "Rumor"),
                                             state: story.status == .confirmed ? .ok : .info))
                if let topic = story.topic { WidgetTagView(tag: WidgetTag(label: topic)) }
                Text([String(localized: "\(story.sources.count) sources"), story.published.flatMap { formatter.relative($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            Text(story.headline).font(WidgetFont.valueSmall).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if let body = story.body { Text(widgetLinking: body).font(WidgetFont.body).foregroundStyle(Theme.secondaryText).lineLimit(3) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Why it matters").font(WidgetFont.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                Text(widgetLinking: story.why).font(WidgetFont.body).fixedSize(horizontal: false, vertical: true)
            }
            .widgetWell()
            if context.view.showsAll {
                ForEach(Array(story.sources.enumerated()), id: \.offset) { _, source in
                    Button { if let url = source.url { context.open(url) } } label: {
                        Label(source.name, systemImage: source.primary ? "checkmark.seal" : "link").font(WidgetFont.label)
                    }
                    .buttonStyle(.plain)
                    .disabled(source.url == nil)
                }
            }
            Button(context.view.showsAll ? String(localized: "Hide the Sources") : String(localized: "Show the Sources")) {
                context.updateView { $0.showsAll.toggle() }
            }
            .font(WidgetFont.label.weight(.semibold))
            .buttonStyle(.plain)
            .frame(minHeight: 32)
        }
    }

    private var standup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((model.people ?? []).enumerated()), id: \.offset) { index, member in
                if index > 0 { Divider().overlay(Theme.hairline) }
                HStack(alignment: .top, spacing: 10) {
                    if let bot = member.person.bot {
                        WidgetBotFace(handle: bot, size: 26)
                    } else {
                        Text(member.person.initials ?? String(member.person.name.prefix(1)))
                            .font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26).background(Theme.controlFill, in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.person.name).font(WidgetFont.body.weight(.semibold))
                        if let done = member.done { Text(String(localized: "Done: \(done)")).font(WidgetFont.label) }
                        if let today = member.today { Text(String(localized: "Today: \(today)")).font(WidgetFont.label) }
                        if let blocked = member.blocked {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                WidgetTagView(tag: WidgetTag(label: String(localized: "Blocked"), state: .warning))
                                Text(blocked).font(WidgetFont.label)
                            }
                        }
                        if let evidence = member.evidence { EvidenceLine(evidence: evidence) }
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - guide

/// Steps the person follows at their own pace, with what they need first and timers; Back and
/// Next are on the device (`Content.guide`, `guideCompact`).
struct GuideBody: View {
    let model: GuideWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsNeeds = false
    @State private var servings: Int?

    /// The step on screen: kept per widget id; an unknown `start_at` opens at step 1.
    private var index: Int {
        let id = context.view.step ?? model.startAt
        return id.flatMap { id in model.steps.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let needs = model.needs, !needs.isEmpty, model.layout == .full { needsRow(needs) }
            if model.layout == .full {
                ForEach(Array(model.steps.enumerated()), id: \.offset) { position, step in
                    if position < index {
                        Label { Text(step.title).foregroundStyle(Theme.secondaryText) } icon: { Image(systemName: "checkmark").foregroundStyle(Theme.success) }
                            .font(WidgetFont.label)
                            .accessibilityLabel(String(localized: "Step \(position + 1), done, \(step.title)"))
                    } else if position == index {
                        current(step, position: position)
                    } else if position == index + 1 {
                        HStack(spacing: 8) {
                            Text("\(position + 1)").font(WidgetFont.caption.weight(.bold)).frame(width: 20, height: 20).background(Theme.controlFill, in: Circle())
                            Text(step.title).font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            } else {
                current(model.steps[index], position: index)
                HStack(spacing: 4) {
                    ForEach(0..<model.steps.count, id: \.self) { dot in
                        Circle().fill(dot == index ? Theme.ink : Theme.controlFill).frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
            bottomBar
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3), value: index)
    }

    private func move(by offset: Int) {
        let next = min(max(index + offset, 0), model.steps.count - 1)
        context.updateView { $0.step = model.steps[next].id }
    }

    private var bottomBar: some View {
        // Plain "‹ Back" and a bold "Next ›" on either side of the count (`Content.guide`).
        HStack {
            Button { move(by: -1) } label: {
                Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon).font(WidgetFont.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(index == 0 ? Theme.tertiaryText : Theme.primaryText)
            .frame(minHeight: 44)
            .disabled(index == 0)
            Spacer()
            Text("Step \(index + 1) of \(model.steps.count)").font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Button {
                if index < model.steps.count - 1 { move(by: 1) }
            } label: {
                HStack(spacing: 4) {
                    Text(index == model.steps.count - 1 ? String(localized: "Done") : String(localized: "Next"))
                    if index < model.steps.count - 1 { Image(systemName: "chevron.right") }
                }
                .font(WidgetFont.body.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primaryText)
            .frame(minHeight: 44)
        }
    }

    private func current(_ step: GuideWidget.Step, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(position + 1)")
                    .font(WidgetFont.caption.weight(.bold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 22, height: 22)
                    .background(Theme.ink, in: Circle())
                Text(step.title).font(WidgetFont.valueSmall).fixedSize(horizontal: false, vertical: true)
            }
            if let body = step.body { Text(widgetLinking: body).font(WidgetFont.body).fixedSize(horizontal: false, vertical: true) }
            if let image = step.image { WidgetImage(media: image, maxHeight: 160) }
            if let check = step.check { Label(check, systemImage: "eye").font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
            if let caution = step.caution { Label(caution, systemImage: "exclamationmark.triangle.fill").font(WidgetFont.label).foregroundStyle(Theme.warning) }
            if let timer = step.timer { GuideTimer(step: step, seconds: timer, context: context) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Step \(position + 1), current. \(step.title)"))
    }

    private func needsRow(_ needs: [GuideWidget.Need]) -> some View {
        let base = model.servings ?? 1
        let shownServings = servings ?? base
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.spring(response: 0.3)) { showsNeeds.toggle() } } label: {
                HStack {
                    Image(systemName: "basket")
                    Text(needsTitle(needs.count)).font(WidgetFont.body)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showsNeeds ? 180 : 0)).font(.system(size: 10, weight: .semibold))
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsNeeds {
                if model.servings != nil {
                    Stepper(String(localized: "Serves \(shownServings)"), value: Binding(get: { shownServings }, set: { servings = max(1, $0) }), in: 1...24)
                        .font(WidgetFont.label)
                }
                ForEach(Array(needs.enumerated()), id: \.offset) { _, need in
                    HStack(alignment: .firstTextBaseline) {
                        Text(need.label).font(WidgetFont.label)
                        Spacer()
                        Text(amount(need, factor: Double(shownServings) / Double(base))).font(WidgetFont.label.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .widgetWell()
    }

    private func needsTitle(_ count: Int) -> String {
        switch model.needsKind {
        case .ingredients: String(localized: "You'll need \(count) ingredients")
        case .equipment: String(localized: "You'll need \(count) things")
        case .items: String(localized: "You'll need \(count) items")
        }
    }

    /// Amounts scale with servings only where the recipe says they do.
    private func amount(_ need: GuideWidget.Need, factor: Double) -> String {
        guard var quantity = need.amount else { return need.note ?? "" }
        if need.scales, case .number(let value)? = quantity.value, factor != 1 {
            quantity.value = .number(value * factor)
            quantity.display = nil
        }
        return [formatter.string(quantity), need.note].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A step's timer chip: Start, Pause and Reset on the device; when it ends, a notification if
/// the app isn't in front.
private struct GuideTimer: View {
    let step: GuideWidget.Step
    let seconds: Double
    let context: WidgetContext

    private var endsAt: Date? { context.view.timers[step.id] }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
            if let endsAt, endsAt > .now {
                Text(timerInterval: Date.now...endsAt, countsDown: true).monospacedDigit()
                Button("Reset") { reset() }.font(WidgetFont.label.weight(.semibold))
            } else {
                Text(WidgetFormatter().duration(seconds)).monospacedDigit()
                Button(endsAt == nil ? String(localized: "Start") : String(localized: "Again")) { start() }.font(WidgetFont.label.weight(.semibold))
            }
        }
        .font(WidgetFont.label)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Theme.controlFill, in: Capsule())
    }

    private func start() {
        let end = Date.now.addingTimeInterval(seconds)
        context.updateView { $0.timers[step.id] = end }
        let content = UNMutableNotificationContent()
        content.title = context.payload.title
        content.body = String(localized: "\(step.title): timer done")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "widget-timer-\(context.payload.id)-\(step.id)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    private func reset() {
        context.updateView { $0.timers[step.id] = nil }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["widget-timer-\(context.payload.id)-\(step.id)"])
    }
}

// MARK: - compare

/// Two to four options side by side, the pick outlined in ink, and what decided it; the weights
/// can be the person's own (`Content.compare`, `compareCards`, `compareWeighted`).
struct CompareBody: View {
    let model: CompareWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var weights: [String: Int] {
        var weights: [String: Int] = [:]
        for criterion in model.criteria ?? [] { weights[criterion.id] = criterion.weight ?? 0 }
        for (key, value) in context.view.weights ?? [:] { weights[key] = value }
        return weights
    }

    /// Σ(weight × score) ÷ Σ(weight) over weighted criteria; unknown values carry no weight.
    private func score(_ option: CompareWidget.Option) -> Double? {
        var total = 0.0, weight = 0.0
        for criterion in model.criteria ?? [] {
            guard let scores = criterion.scores, let value = scores[option.id], let w = weights[criterion.id], w > 0 else { continue }
            total += Double(w * value)
            weight += Double(w)
        }
        return weight > 0 ? total / weight : nil
    }

    private var top: CompareWidget.Option? {
        guard model.adjustable else { return model.options.first { $0.id == model.pick } }
        return model.options.max { (score($0) ?? -1) < (score($1) ?? -1) }
    }

    private var selected: String? { context.view.filter ?? top?.id }

    private var usesCards: Bool {
        switch model.layout {
        case .cards: true
        case .grid: false
        case .auto: (sizeClass == .regular || context.density == .compact) && model.options.allSatisfy { $0.pros != nil || $0.cons != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if usesCards || typeSize.isAccessibilitySize { cards } else { grid }
            decidingLine
            if model.adjustable {
                Text("Weights are yours: change them and the scores re-rank here, without asking Hermes.")
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            if model.adjustable || model.choose {
                HStack(spacing: 8) {
                    if model.adjustable {
                        Button("Reset Weights") { context.updateView { $0.weights = nil } }
                            .buttonStyle(WidgetActionButtonStyle())
                            .disabled(context.view.weights == nil)
                    }
                    if model.choose, let chosen = model.options.first(where: { $0.id == selected }) {
                        Button(String(localized: "Go with \(chosen.name)")) {
                            context.answer(.compare(context.payload, model, option: chosen.id, weights: model.adjustable ? weights : nil))
                        }
                        .buttonStyle(WidgetActionButtonStyle(role: .primary, isPending: context.pendingAction == "answer"))
                        .disabled(!context.canAnswer || (model.adjustable && weights.values.allSatisfy { $0 == 0 }))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var decidingLine: some View {
        let changed = model.adjustable && top?.id != model.pick && context.view.weights != nil
        if changed, let top, let score = score(top) {
            Label(String(localized: "With your weights, \(top.name) comes first (\(WidgetFormatter.number(score, digits: 1)))"), systemImage: "checkmark.seal")
                .font(WidgetFont.label)
        } else if let decided = model.decidedBy {
            Label {
                if let pick = model.options.first(where: { $0.id == model.pick }) {
                    Text("\(Text(pick.name).fontWeight(.bold)): \(decided)")
                } else {
                    Text(decided)
                }
            } icon: { Image(systemName: "checkmark.seal") }
            .font(WidgetFont.label)
        }
    }

    /// The column the option highlighted: the pick, or the one chosen or ranked first.
    private var highlighted: String? { model.adjustable ? top?.id : (selected ?? model.pick) }

    /// `Content.compare`: a narrow label column, then one equal column per option, the pick
    /// outlined in ink. More options than fit scroll sideways, at a fixed column width.
    private var grid: some View {
        let scrolls = model.options.count > 3 && sizeClass != .regular
        let labelWidth: CGFloat = context.density == .compact ? 72 : 84
        let table = Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow(alignment: .bottom) {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(model.options, id: \.id) { option in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.name)
                            .font(WidgetFont.label.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if option.id == model.pick { WidgetTagView(tag: WidgetTag(label: String(localized: "Pick"), state: .new), prominent: true) }
                    }
                    .compareColumn(option.id == highlighted, width: scrolls ? 108 : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.choose { context.updateView { $0.filter = option.id } } }
                }
            }
            ForEach(model.criteria ?? [], id: \.id) { criterion in
                GridRow(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(criterion.label)
                            .font(WidgetFont.label)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.adjustable, criterion.scores != nil { weightStepper(criterion) }
                    }
                    .frame(width: labelWidth, alignment: .leading)
                    ForEach(model.options, id: \.id) { option in
                        let value = criterion.values[option.id]?.string(formatter) ?? WidgetFormatter.unknown
                        let best = criterion.best?.contains(option.id) == true
                        Text(value)
                            .font(WidgetFont.body.weight(best ? .semibold : .regular).monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                            .compareColumn(option.id == highlighted, width: scrolls ? 108 : nil)
                            .accessibilityLabel(best ? String(localized: "\(value), best") : value)
                    }
                }
            }
            if model.adjustable {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Score").font(WidgetFont.label.weight(.semibold)).frame(width: labelWidth, alignment: .leading)
                    ForEach(model.options, id: \.id) { option in
                        Text(score(option).map { WidgetFormatter.number($0, digits: 1) } ?? WidgetFormatter.unknown)
                            .font(WidgetFont.body.weight(.semibold).monospacedDigit())
                            .compareColumn(option.id == highlighted, width: scrolls ? 108 : nil)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .overlayPreferenceValue(CompareColumnBounds.self) { anchors in
            GeometryReader { proxy in
                if let first = anchors.first {
                    let rect = anchors.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.ink, lineWidth: 1.5)
                        .frame(width: rect.width + 12, height: rect.height + 16)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .accessibilityHidden(true)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) { table.padding(.horizontal, 8) }
            } else {
                table.padding(.horizontal, 6)
            }
            // How a value is known, below the table rather than in its narrow label column.
            ForEach((model.criteria ?? []).filter { $0.evidence != nil }, id: \.id) { criterion in
                if let evidence = criterion.evidence { EvidenceLine(evidence: evidence) }
            }
        }
    }

    private func weightStepper(_ criterion: CompareWidget.Criterion) -> some View {
        let weight = weights[criterion.id] ?? 0
        return HStack(spacing: 6) {
            Button { set(criterion, weight - 1) } label: { Image(systemName: "minus").frame(width: 28, height: 28) }.disabled(weight <= 0)
            Text("\(weight)").font(WidgetFont.label.monospacedDigit())
            Button { set(criterion, weight + 1) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.disabled(weight >= 5)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(criterion.label), weight \(weight) of 5"))
        .accessibilityAdjustableAction { direction in set(criterion, direction == .increment ? weight + 1 : weight - 1) }
    }

    private func set(_ criterion: CompareWidget.Criterion, _ weight: Int) {
        context.updateView { view in
            var weights = view.weights ?? [:]
            weights[criterion.id] = min(max(weight, 0), 5)
            view.weights = weights
        }
    }

    private var cards: some View {
        let layout = typeSize.isAccessibilitySize || sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            ForEach(model.options, id: \.id) { option in
                let picked = option.id == (model.adjustable ? top?.id : model.pick)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(option.name).font(WidgetFont.body.weight(.semibold))
                        if picked { WidgetTagView(tag: WidgetTag(label: String(localized: "Pick"), state: .new), prominent: true) }
                    }
                    if let price = option.price { Text(formatter.string(price)).font(WidgetFont.value.monospacedDigit()) }
                    ForEach(option.pros ?? [], id: \.self) { pro in Label(pro, systemImage: "plus").font(WidgetFont.label) }
                    ForEach(option.cons ?? [], id: \.self) { con in Label(con, systemImage: "minus").font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
                    if typeSize.isAccessibilitySize {
                        ForEach(model.criteria ?? [], id: \.id) { criterion in
                            Text("\(criterion.label): \(criterion.values[option.id]?.string(formatter) ?? WidgetFormatter.unknown)").font(WidgetFont.label)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
                .overlay {
                    if picked || option.id == selected && model.choose {
                        RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if model.choose { context.updateView { $0.filter = option.id } } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }
}

// MARK: - handoff

/// Who handed what to whom and how it's going (`Content.handoff`, `handoffDone`).
struct HandoffBody: View {
    let model: HandoffWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.widgetHost) private var host

    private var isStale: Bool { WidgetClock.staleAt(context.payload.envelope).map { context.now >= $0 } ?? false }

    var body: some View {
        if model.status.state == .done, let result = model.status.result {
            done(result)
        } else {
            working
        }
    }

    private func face(_ person: WidgetPerson, size: CGFloat = 28) -> some View {
        Group {
            if let bot = person.bot {
                WidgetBotFace(handle: bot, size: size)
            } else {
                Text(person.initials ?? String(person.name.prefix(1)))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(Theme.controlFill, in: Circle())
            }
        }
        .accessibilityLabel(person.name)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                face(model.from)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText).accessibilityHidden(true)
                face(model.to)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "\(model.from.name) asked \(model.to.name)")).font(WidgetFont.body.weight(.semibold))
                    Text(model.task.title).font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "\(model.from.name) asked \(model.to.name) \(model.task.title)"))
            if let context = model.task.context {
                HStack(alignment: .top, spacing: 10) {
                    Capsule().fill(Theme.hairline).frame(width: 3)
                    Text(widgetLinking: context).font(WidgetFont.label).foregroundStyle(Theme.primaryText).fixedSize(horizontal: false, vertical: true)
                }
                .widgetWell()
            }
            HStack(spacing: 6) {
                if model.status.state == .declined {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                } else if model.status.state == .working {
                    // Still, three dots: the other side is at work (`Content.handoff`), no animation.
                    HStack(spacing: 3) {
                        ForEach([Theme.secondaryText, Theme.tertiaryText, Theme.tertiaryText.opacity(0.5)], id: \.self) { color in
                            Circle().fill(color).frame(width: 5, height: 5)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(statusLine).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if model.status.state != .declined, let chat = model.chat {
                Button(String(localized: "Open \(model.to.name)'s Chat")) { openChat(chat.session) }
                    .buttonStyle(WidgetActionButtonStyle())
            }
        }
    }

    private var statusLine: String {
        let name = model.to.name
        let progress = model.status.done.flatMap { done in model.status.total.map { String(localized: "\(done) of \($0) \(model.status.unit ?? "")").trimmingCharacters(in: .whitespaces) } }
        switch model.status.state {
        case .sent:
            return [model.sentAt.flatMap { formatter.time($0) }.map { String(localized: "Sent \($0)") }, String(localized: "not picked up yet")].compactMap { $0 }.joined(separator: " · ")
        case .accepted:
            return String(localized: "\(name) accepted")
        case .working:
            let activity = model.status.activity ?? String(localized: "is working")
            if isStale, let asOf = formatter.time(context.payload.envelope.asOf) {
                return [String(localized: "Last update \(asOf)"), "\(name) \(activity)", progress].compactMap { $0 }.joined(separator: " · ")
            }
            // `activity` is the app's activity words ("is writing"); the name goes in front.
            return ["\(name) \(activity)", progress].compactMap { $0 }.joined(separator: " · ")
        case .declined:
            return String(localized: "\(name) declined: \(model.status.reason ?? "")")
        case .done:
            return String(localized: "\(name) finished")
        }
    }

    private func done(_ result: HandoffWidget.Status.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                face(model.to)
                VStack(alignment: .leading, spacing: 2) {
                    Label(String(localized: "\(model.to.name) finished"), systemImage: "checkmark.circle.fill")
                        .font(WidgetFont.body.weight(.semibold))
                        .foregroundStyle(Theme.success)
                    Text(result.summary).font(WidgetFont.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if let url = result.url {
                Button(result.label ?? String(localized: "Open")) { context.open(url) }
                    .buttonStyle(WidgetActionButtonStyle(role: .primary))
            }
        }
    }

    /// In-app: the other Bot's Bot Chat, or the chat with that session; no message is sent.
    private func openChat(_ session: String) {
        guard let workspace = host?.conversation?.workspace else { return }
        if let bot = model.to.bot, workspace.roster?.bot(named: bot) != nil {
            workspace.sidebarMode = .bots
            workspace.selection = .bot(bot)
        } else if let found = workspace.sessions.first(where: { $0.id == session }) {
            workspace.sidebarMode = .chats
            workspace.selection = .session(found.stableID)
        }
    }
}

// MARK: - flashcard

/// A review session: the question, revealed on tap, then how well you knew it; the ratings go
/// in one message when the session ends (`Content.flashcard`, `flashcardBack`).
struct FlashcardBody: View {
    let model: FlashcardWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsHint = false

    private var rated: [(card: String, rating: WidgetAnswer.Rating)] { context.host?.store.ratings[context.payload.id] ?? [] }
    private var position: Int { min(context.view.card, max(model.cards.count - 1, 0)) }

    var body: some View {
        if model.cards.isEmpty {
            WidgetEmpty(context: context, fallback: emptyText)
        } else if context.pendingAction == "rate" || (rated.count >= model.cards.count && context.interaction != .resolved) {
            Label(String(localized: "Saving \(rated.count) ratings…"), systemImage: "hourglass")
                .font(WidgetFont.body)
                .foregroundStyle(Theme.secondaryText)
        } else {
            session
        }
    }

    private var emptyText: String {
        guard let next = model.nextDue, let date = WidgetClock.date(next) else { return String(localized: "Nothing to review today.") }
        let when = Calendar.current.isDateInToday(date) ? String(localized: "at \(formatter.time(next) ?? "")") : (Calendar.current.isDateInTomorrow(date) ? String(localized: "tomorrow") : String(localized: "on \(formatter.date(next) ?? next)"))
        return String(localized: "Nothing to review today. Next cards are due \(when).")
    }

    private var session: some View {
        let card = model.cards[position]
        let revealed = context.view.revealed
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35)) { context.updateView { $0.revealed = true } }
            } label: {
                VStack(spacing: 8) {
                    if let media = card.media { WidgetImage(media: media, maxHeight: 120) }
                    Text(revealed ? card.back : card.front)
                        .font(WidgetFont.question)
                        .multilineTextAlignment(.center)
                        .environment(\.locale, Locale(identifier: (revealed ? card.backLang : card.frontLang) ?? formatter.locale.identifier))
                    if revealed, let example = card.example {
                        Text(example).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    }
                    if !revealed {
                        Text("Tap the card to see the answer").font(WidgetFont.caption).foregroundStyle(Theme.tertiaryText)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .rotation3DEffect(.degrees(revealed && !reduceMotion ? 360 : 0), axis: (x: 0, y: 1, z: 0))
            }
            .buttonStyle(.plain)
            .disabled(revealed)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(revealed ? card.back : card.front)
            .accessibilityHint(revealed ? "" : String(localized: "Shows the answer"))
            if !revealed, let hint = card.hint {
                Button(showsHint ? hint : String(localized: "Show Hint")) { showsHint = true }
                    .font(WidgetFont.label).buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
            }
            if revealed {
                ratingTiles(card)
            } else {
                HStack {
                    WidgetBar(fraction: Double(model.progress.done + position) / Double(max(model.progress.total, 1)), height: 4)
                    Text("\(model.progress.done + position + 1) of \(model.progress.total)").font(WidgetFont.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    if !rated.isEmpty {
                        Button("Done") { context.host?.store.flush(context.payload.id) }.font(WidgetFont.label.weight(.semibold)).buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func ratingTiles(_ card: FlashcardWidget.Card) -> some View {
        let ratings: [(WidgetAnswer.Rating, String, String?)] = [
            (.again, String(localized: "Again"), card.intervals?.again), (.hard, String(localized: "Hard"), card.intervals?.hard),
            (.good, String(localized: "Good"), card.intervals?.good), (.easy, String(localized: "Easy"), card.intervals?.easy),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Array(ratings.enumerated()), id: \.offset) { number, entry in
                Button {
                    context.host?.rate(card.id, entry.0, in: context.payload, total: model.cards.count)
                    context.updateView { view in
                        view.revealed = false
                        view.card = min(view.card + 1, model.cards.count - 1)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(entry.1).font(WidgetFont.label.weight(.semibold))
                        if let interval = entry.2 { Text(interval).font(WidgetFont.caption).opacity(0.75) }
                    }
                    .foregroundStyle(entry.0 == .good ? Theme.inkForeground : Theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(entry.0 == .good ? Theme.ink : Theme.controlFill, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(number + 1)")), modifiers: [])
                .accessibilityLabel([entry.1, entry.2.map { String(localized: "see it again in \($0)") }].compactMap { $0 }.joined(separator: ", "))
            }
        }
        .disabled(!context.canAnswer)
    }
}

// MARK: - stack

/// Several widgets sent as one: a header line and its children, in sections that fold, as rows,
/// a carousel or a grid (`Composition.stack`). It has no card of its own.
struct StackBody: View {
    let model: StackWidget
    let context: WidgetContext

    @Environment(\.widgetHost) private var host
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Children draw compact in a stack of four or more.
    private var density: WidgetDensity { model.children.count >= 4 ? .compact : context.density }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch layout {
            case .collapsed: collapsed
            case .carousel: carousel
            case .grid: grid
            case .list: list
            }
        }
        .environment(\.widgetDensity, density)
    }

    /// A carousel holds one type, or it draws as a list; a grid is one column on a phone.
    private var layout: StackWidget.Layout {
        if typeSize.isAccessibilitySize, model.layout != .collapsed { return .list }
        if model.layout == .carousel, Set(model.children.compactMap { $0.payload?.type }).count > 1 { return .list }
        #if os(iOS)
        if model.layout == .grid, sizeClass == .compact { return .list }
        #endif
        return model.layout
    }

    @ViewBuilder
    private func child(_ child: WidgetStackChild) -> some View {
        // A child's own newer revision wins: an update to a child replaces just it.
        switch child {
        case .payload(let payload):
            if let newer = host?.store.payload(payload.id), newer.rev > payload.rev {
                WidgetCard(payload: newer)
            } else {
                WidgetCard(payload: payload)
            }
        case .unreadable(let json):
            if case .fallback(let fallback) = WidgetReader.read(json) { WidgetFallbackView(fallback: fallback) }
        }
    }

    private var list: some View {
        let sections = model.sections ?? []
        let sectioned = Set(sections.flatMap(\.children))
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.children.enumerated()), id: \.offset) { _, item in
                if let id = item.id, !sectioned.contains(id) { child(item) }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                let key = "section-\(index)"
                let open = section.folded ? context.view.expanded.contains(key) : !context.view.expanded.contains(key)
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        context.updateView { view in
                            if view.expanded.contains(key) { view.expanded.remove(key) } else { view.expanded.insert(key) }
                        }
                    }
                } label: {
                    // The section's name on the left, its chevron at the right edge (`Composition.stack`).
                    HStack(spacing: 4) {
                        Text(section.label).font(WidgetFont.label.weight(.semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(open ? String(localized: "expanded") : String(localized: "collapsed"))
                if open {
                    ForEach(section.children, id: \.self) { id in
                        if let item = model.children.first(where: { $0.id == id }) { child(item) }
                    }
                }
            }
        }
    }

    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.children.enumerated()), id: \.offset) { _, item in
                let id = item.id ?? ""
                if context.view.expanded.contains(id) {
                    child(item)
                        .onTapGesture(count: 2) { context.updateView { $0.expanded.remove(id) } }
                } else if let payload = item.payload {
                    Button { withAnimation(.spring(response: 0.3)) { context.updateView { $0.expanded.insert(id) } } } label: {
                        HStack(spacing: 10) {
                            WidgetGlyph(name: payload.envelope.icon, fallback: payload.type.defaultSymbol, size: 13)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(payload.title).font(WidgetFont.body.weight(.semibold)).foregroundStyle(Theme.primaryText)
                                if let summary = payload.envelope.summary {
                                    Text(summary).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 6)
                            if let badge = WidgetHeader.badge(for: payload, now: context.now) { WidgetBadge(tone: badge.tone, word: badge.word) }
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 52)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: density.radius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel([payload.title, payload.envelope.summary, String(localized: "collapsed")].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint(String(localized: "Shows the widget"))
                } else {
                    child(item)
                }
            }
        }
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(Array(model.children.enumerated()), id: \.offset) { _, item in
                    child(item).frame(width: 310)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(Array(model.children.enumerated()), id: \.offset) { _, item in child(item) }
        }
    }
}

/// The cells of the highlighted compare column, so one outline can go around them.
nonisolated private struct CompareColumnBounds: SwiftUI.PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

private extension View {
    /// An option's cell: equal width (or a fixed one when the table scrolls), outlined with its column.
    @ViewBuilder
    func compareColumn(_ highlighted: Bool, width: CGFloat?) -> some View {
        let sized = Group {
            if let width { frame(width: width, alignment: .leading) } else { frame(maxWidth: .infinity, alignment: .leading) }
        }
        if highlighted {
            sized.anchorPreference(key: CompareColumnBounds.self, value: .bounds) { [$0] }
        } else {
            sized
        }
    }
}
