import HermesKit
import HermesPush
import SwiftUI

// The Asking family (`widgets/asking.elyx`): choice, form, approval, receipt, control. Every tap
// is a request: the card sends the answer as Send Next and shows it pending until the agent's
// update (`docs/widgets.md` §5).

// MARK: - choice

/// One question with set answers: rows, buttons, chips, a rating, times, or several to tick
/// (`Asking.choice`, `choiceChips`, `choiceMulti`, `choiceRating`, `choiceTimes`,
/// `choiceAnswered`). Suggestions have no card (`SuggestionRows`).
struct ChoiceBody: View {
    let model: ChoiceWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    /// What was chosen: the agent's recorded answer, else the answer waiting in the chat.
    private var chosen: Set<String> {
        if let answer = model.answer { return Set(answer.selected) }
        if case .array(let ids)? = context.pendingValues?["selected"] { return Set(ids.compactMap(\.stringValue)) }
        return []
    }

    private var isPending: Bool { context.pendingAction == "answer" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = model.question {
                Text(question).font(WidgetFont.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if model.select == .many {
                multi
            } else {
                switch model.style {
                case .buttons where !typeSize.isAccessibilitySize: buttons
                case .chips: chips
                case .rating: rating
                case .times: times
                default: rows
                }
            }
            if let decline = model.declineLabel, model.answer == nil {
                Button(decline) { send([], words: decline) }
                    .font(WidgetFont.label.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .buttonStyle(.plain)
                    .frame(minHeight: 36)
                    .disabled(!context.canAnswer)
            }
            if let note = model.note {
                Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func send(_ ids: [String], other: String? = nil, words: String? = nil) {
        var answer = WidgetAnswer.choice(context.payload, model, selected: ids, other: other)
        if let words { answer.words = words }
        context.answer(answer)
    }

    // MARK: Styles

    /// `Asking.choice`: each option a white card, the suggested one (or the one chosen) outlined in ink.
    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.options.enumerated()), id: \.offset) { _, option in
                let outlined = chosen.isEmpty ? option.recommended : chosen.contains(option.id)
                Button { send([option.id]) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(option.label).font(WidgetFont.body.weight(.semibold)).foregroundStyle(Theme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                if option.recommended {
                                    Text("Suggested").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            if let detail = option.detail {
                                Text(detail).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 8)
                        trailing(option)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: context.density.rowHeight, alignment: .leading)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if outlined {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.5)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(!context.canAnswer)
                .opacity(dims(option) ? 0.45 : 1)
                .accessibilityLabel(spoken(option))
                .accessibilityAddTraits(chosen.contains(option.id) ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func trailing(_ option: ChoiceWidget.Option) -> some View {
        if chosen.contains(option.id), isPending {
            PendingGlyph()
        } else if chosen.contains(option.id) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primaryText)
        } else if context.canAnswer {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
        }
    }

    private func dims(_ option: ChoiceWidget.Option) -> Bool {
        !chosen.isEmpty && !chosen.contains(option.id)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.options.prefix(3).enumerated()), id: \.offset) { _, option in
                Button(option.label) { send([option.id]) }
                    .buttonStyle(WidgetActionButtonStyle(role: option.recommended ? .primary : .secondary,
                                                         isPending: isPending && chosen.contains(option.id)))
                    .disabled(!context.canAnswer)
                    .opacity(dims(option) ? 0.45 : 1)
                    .accessibilityLabel(spoken(option))
            }
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(model.options.enumerated()), id: \.offset) { _, option in
                let picked = chosen.contains(option.id)
                Button { send([option.id]) } label: {
                    HStack(spacing: 5) {
                        if picked, isPending { PendingGlyph(color: Theme.inkForeground) }
                        Text(option.label).font(WidgetFont.label.weight(.semibold))
                    }
                    .foregroundStyle(picked || option.recommended ? Theme.inkForeground : Theme.primaryText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(picked || option.recommended ? Theme.ink : Theme.controlFill, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(!context.canAnswer)
                .opacity(dims(option) ? 0.45 : 1)
                .accessibilityLabel(spoken(option))
            }
        }
    }

    @ViewBuilder
    private var rating: some View {
        let options = model.options
        let picked = options.firstIndex { chosen.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: model.rating == .thumbs ? 16 : 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        var answer = WidgetAnswer.choice(context.payload, model, selected: [option.id])
                        if model.rating == .stars {
                            answer.words = String(localized: "\(index + 1) of \(options.count) stars · \(option.label)")
                        }
                        context.answer(answer)
                    } label: {
                        Group {
                            switch model.rating {
                            case .thumbs:
                                Image(systemName: index == 0 ? "hand.thumbsdown" : "hand.thumbsup")
                                    .symbolVariant(picked == index ? .fill : .none)
                            case .scale:
                                Text("\(index + 1)").font(WidgetFont.valueSmall)
                                    .frame(width: 36, height: 36)
                                    .background(picked == index ? Theme.ink : Theme.controlFill, in: Circle())
                                    .foregroundStyle(picked == index ? Theme.inkForeground : Theme.primaryText)
                            case .stars:
                                Image(systemName: (picked ?? -1) >= index ? "star.fill" : "star")
                            }
                        }
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.primaryText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!context.canAnswer)
                    .accessibilityLabel(model.rating == .stars ? String(localized: "\(index + 1) of \(options.count) stars, \(option.label)") : option.label)
                }
            }
            if let first = options.first, let last = options.last, options.count > 1 {
                HStack {
                    Text(first.label)
                    Spacer()
                    Text(last.label)
                }
                .font(WidgetFont.caption)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            }
        }
    }

    private var times: some View {
        let days = Dictionary(grouping: model.options.enumerated(), by: { entry in entry.element.at.flatMap { formatter.date($0) } ?? "" })
        let order = model.options.compactMap { $0.at.flatMap { formatter.date($0) } }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(order, id: \.self) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(day).font(WidgetFont.label.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach((days[day] ?? []).map(\.element), id: \.id) { option in
                            let picked = chosen.contains(option.id)
                            Button {
                                let time = option.at.flatMap { formatter.time($0) } ?? option.label
                                var answer = WidgetAnswer.choice(context.payload, model, selected: [option.id])
                                answer.words = "\(day), \(time)"
                                context.answer(answer)
                            } label: {
                                Text(option.at.flatMap { formatter.time($0) } ?? option.label)
                                    .font(WidgetFont.label.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(picked ? Theme.inkForeground : Theme.primaryText)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(picked ? Theme.ink : Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous).strokeBorder(option.recommended ? Theme.ink : .clear))
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(!context.canAnswer)
                            .accessibilityLabel("\(day), \(option.at.flatMap { formatter.time($0) } ?? option.label)")
                        }
                    }
                }
            }
        }
    }

    private var multi: some View {
        let picked = model.answer.map { Set($0.selected) } ?? (context.pendingValues != nil ? chosen : context.view.selected)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.options.enumerated()), id: \.offset) { _, option in
                Button {
                    context.updateView { view in
                        if view.selected.contains(option.id) { view.selected.remove(option.id) } else { view.selected.insert(option.id) }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: picked.contains(option.id) ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18))
                            .foregroundStyle(picked.contains(option.id) ? Theme.ink : Theme.tertiaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(WidgetFont.body).foregroundStyle(Theme.primaryText)
                            if let detail = option.detail { Text(detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!context.canAnswer)
                .accessibilityLabel(option.label)
                .accessibilityValue(picked.contains(option.id) ? String(localized: "ticked") : String(localized: "not ticked"))
            }
            if let other = model.other, context.canAnswer {
                TextField(other.placeholder ?? String(localized: "Other"), text: Binding(
                    get: { context.view.other }, set: { text in context.updateView { $0.other = text } }
                ))
                .textFieldStyle(.plain)
                .font(WidgetFont.body)
                .padding(10)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
            }
            if model.answer == nil {
                let count = context.view.selected.count + (context.view.other.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
                Button(count == 1 ? String(localized: "Send 1 Choice") : String(localized: "Send \(count) Choices")) {
                    let ids = model.options.map(\.id).filter { context.view.selected.contains($0) }
                    let other = context.view.other
                    send(ids, other: other.isEmpty ? nil : other)
                }
                .buttonStyle(WidgetActionButtonStyle(role: .primary, isPending: isPending))
                .disabled(!context.canAnswer || count == 0)
                .padding(.top, 6)
            }
        }
    }

    private func spoken(_ option: ChoiceWidget.Option) -> String {
        [option.label.replacingOccurrences(of: "→", with: String(localized: "to")), option.detail,
         option.recommended ? String(localized: "recommended") : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Suggested follow-ups (`Asking.choiceSuggestions`): plain rows under the reply, no card. A tap
/// sends the row's words as the person's own message; they show only while their reply is the last
/// thing in the chat.
struct SuggestionRows: View {
    let payload: WidgetPayload
    let model: ChoiceWidget

    @Environment(\.widgetHost) private var host
    @Environment(\.widgetPreview) private var preview

    /// In a chat, only under the newest reply once it's done; in the gallery, always.
    private var shows: Bool {
        guard let host else { return preview != nil }
        return host.facts.lastReplyWidgets.contains(payload.id) && host.conversation?.isWorking == false
    }

    var body: some View {
        if shows {
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                ForEach(Array(model.options.prefix(3).enumerated()), id: \.offset) { _, option in
                    Button { host?.sendSuggestion(option.label) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            Text(option.label).font(WidgetFont.body).foregroundStyle(Theme.primaryText).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(String(localized: "Suggested message: \(option.label)"))
                    .accessibilityHint(String(localized: "Sends it as your message"))
                }
            }
            .frame(maxWidth: WidgetDensity.maxWidth, alignment: .leading)
        }
    }
}

// MARK: - form

/// A few things the agent needs filled in, sent in one go (`Asking.form`, `formSent`). Drafts stay
/// on this device until Send.
struct FormBody: View {
    let model: FormWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let intro = model.intro {
                Text(intro).font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
            }
            if let submitted = model.submitted {
                sent(submitted)
            } else {
                ForEach(model.fields, id: \.id) { field in FormFieldView(field: field, context: context) }
                if context.interaction != .resolved {
                    HStack(spacing: 8) {
                        Button("Cancel") { context.answer(.cancelForm(context.payload)) }
                            .buttonStyle(WidgetActionButtonStyle(isPending: context.pendingAction == "cancel"))
                        Button(model.submitLabel) { context.answer(.form(context.payload, model, values: values)) }
                            .buttonStyle(WidgetActionButtonStyle(role: .primary, isPending: context.pendingAction == "submit"))
                            .disabled(!isComplete)
                            .accessibilityHint(isComplete ? "" : String(localized: "\(missingCount) required fields empty"))
                    }
                    .disabled(!context.canAnswer)
                }
            }
        }
    }

    private func sent(_ submitted: [String: WidgetValue]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.fields.enumerated()), id: \.offset) { index, field in
                if index > 0 { Divider().overlay(Theme.hairline) }
                HStack(alignment: .firstTextBaseline) {
                    Text(field.label).font(WidgetFont.body).foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 10)
                    Text(FormFieldView.display(submitted[field.id], field: field, formatter: formatter))
                        .font(WidgetFont.body).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Every field's value: the draft, else the agent's default; empty optional fields are null.
    private var values: [String: WidgetValue] {
        var values: [String: WidgetValue] = [:]
        for field in model.fields {
            values[field.id] = FormFieldView.value(field, draft: context.view.draft[field.id]) ?? .null
        }
        return values
    }

    private var missingCount: Int {
        model.fields.filter { field in
            guard field.required else { return false }
            let value = FormFieldView.value(field, draft: context.view.draft[field.id])
            if case .string(let text)? = value { return text.trimmingCharacters(in: .whitespaces).isEmpty }
            return value == nil || value == .null
        }.count
    }

    private var isComplete: Bool {
        missingCount == 0 && model.fields.allSatisfy { FormFieldView.problem($0, value: FormFieldView.value($0, draft: context.view.draft[$0.id])) == nil }
    }
}

/// One form field: its label (with "required"), the input in a canvas well, and its problem or help.
private struct FormFieldView: View {
    let field: FormWidget.Field
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @State private var picksDate = false

    private var value: WidgetValue? { Self.value(field, draft: context.view.draft[field.id]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if field.kind != .toggle {
                HStack(spacing: 2) {
                    Text(field.label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                    if field.required { Text("*").font(WidgetFont.label.weight(.semibold)).foregroundStyle(Theme.danger).accessibilityHidden(true) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(field.required ? String(localized: "\(field.label), required") : field.label)
            }
            input
            if let problem = Self.problem(field, value: value) {
                Label(problem, systemImage: "exclamationmark.circle").font(WidgetFont.caption).foregroundStyle(Theme.danger)
            } else if let help = field.help {
                Text(help).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func set(_ json: JSONValue?) {
        context.updateView { view in view.draft[field.id] = json }
    }

    @ViewBuilder
    private var input: some View {
        switch field.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value?.bool ?? false }, set: { set(.bool($0)) })) {
                // The label takes the row, so the switch sits at the end on the Mac too.
                Text(field.label).font(WidgetFont.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            // A switch on the Mac too, where a plain toggle is a checkbox (`Asking.form`).
            .toggleStyle(.switch)
            .tint(Theme.success)
        case .choice:
            // The whole well opens the menu, its up-down chevrons at the end (`Asking.form`).
            Menu {
                Picker(field.label, selection: Binding(get: { value?.string ?? "" }, set: { set(.string($0)) })) {
                    if !field.required || value == nil { Text("—").tag("") }
                    ForEach(field.options ?? [], id: \.id) { option in Text(option.label).tag(option.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack {
                    let chosen = field.options?.first { $0.id == value?.string }?.label
                    Text(chosen ?? field.placeholder ?? "—")
                        .foregroundStyle(chosen == nil ? Theme.tertiaryText : Theme.primaryText)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                }
                .font(WidgetFont.body)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .well()
            .accessibilityLabel(field.label)
            .accessibilityValue(field.options?.first { $0.id == value?.string }?.label ?? "")
        case .date, .time, .datetime:
            // The date as words ("Fri 30 Oct") with the calendar glyph; the calendar opens over it.
            Button { picksDate = true } label: {
                HStack {
                    Text(dateValue.map(dateText) ?? field.placeholder ?? "—")
                        .foregroundStyle(dateValue == nil ? Theme.tertiaryText : Theme.primaryText)
                    Spacer(minLength: 8)
                    Image(systemName: field.kind == .time ? "clock" : "calendar").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                .font(WidgetFont.body)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .well()
            .accessibilityLabel(field.label)
            .accessibilityValue(dateValue.map(dateText) ?? "")
            .popover(isPresented: $picksDate) {
                DatePicker(field.label, selection: Binding(get: { dateValue ?? .now }, set: { set(.string(encode($0))) }),
                           in: dateRange,
                           displayedComponents: field.kind == .date ? [.date] : field.kind == .time ? [.hourAndMinute] : [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .frame(minWidth: 320)
                    .presentationCompactAdaptation(.popover)
            }
        case .longText:
            TextField(field.placeholder ?? "", text: textBinding, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(WidgetFont.body)
                .well()
        case .number:
            HStack {
                TextField(field.placeholder ?? "", text: textBinding)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if let unit = field.unit ?? field.currency { Text(unit).foregroundStyle(Theme.secondaryText) }
            }
            .font(WidgetFont.body)
            .well()
        default:
            TextField(field.placeholder ?? "", text: textBinding)
                .textFieldStyle(.plain)
                .font(WidgetFont.body)
                #if os(iOS)
                .keyboardType(field.kind == .email ? .emailAddress : field.kind == .phone ? .phonePad : .default)
                .textInputAutocapitalization(field.kind == .email ? .never : .sentences)
                #endif
                .well()
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: {
            switch value {
            case .string(let text)?: text
            case .number(let number)?: WidgetValue.number(number).plainText
            default: ""
            }
        }, set: { text in
            if field.kind == .number {
                set(text.isEmpty ? .null : Double(text.replacingOccurrences(of: ",", with: ".")).map(JSONValue.number) ?? .string(text))
            } else {
                set(.string(String(text.prefix(field.maxLength ?? 2000))))
            }
        })
    }

    private var dateValue: Date? {
        guard let raw = value?.string else { return nil }
        if field.kind == .time {
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: .now)
        }
        if let components = JSONSchemaValidator.parseDate(raw) { return Calendar.current.date(from: components) }
        return WidgetClock.date(raw)
    }

    private func dateText(_ date: Date) -> String {
        switch field.kind {
        case .date: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .time: date.formatted(.dateTime.hour().minute())
        default: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
    }

    /// The earliest and latest the field takes (`min`, `max`).
    private var dateRange: ClosedRange<Date> {
        func bound(_ raw: WidgetValue?) -> Date? {
            guard let text = raw?.string else { return nil }
            if let components = JSONSchemaValidator.parseDate(text) { return Calendar.current.date(from: components) }
            return WidgetClock.date(text)
        }
        let low = field.kind == .time ? nil : bound(field.min)
        let high = field.kind == .time ? nil : bound(field.max)
        return (low ?? .distantPast)...max(high ?? .distantFuture, low ?? .distantPast)
    }

    /// Dates as `2026-10-31`, times as `12:30`, date-times as RFC 3339 (contract §6.1).
    private func encode(_ date: Date) -> String {
        switch field.kind {
        case .date: return date.formatted(.iso8601.year().month().day())
        case .time:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        default: return date.formatted(.iso8601)
        }
    }

    static func value(_ field: FormWidget.Field, draft: JSONValue?) -> WidgetValue? {
        if let draft {
            switch draft {
            case .string(let text): return .string(text)
            case .number(let number): return .number(number)
            case .bool(let on): return .bool(on)
            default: return nil
            }
        }
        if field.kind == .toggle, field.default == nil { return .bool(false) }
        return field.default
    }

    /// Out of range, not an email: shown under the field, and Send waits.
    static func problem(_ field: FormWidget.Field, value: WidgetValue?) -> String? {
        switch (field.kind, value) {
        case (.email, .string(let text)?) where !text.isEmpty && !(text.contains("@") && text.contains(".")):
            return String(localized: "That doesn't look like an email address")
        case (.number, .string(let text)?) where !text.isEmpty:
            return String(localized: "Enter a number")
        case (.number, .number(let number)?):
            if let min = field.min?.number, number < min { return String(localized: "At least \(WidgetValue.number(min).plainText)") }
            if let max = field.max?.number, number > max { return String(localized: "At most \(WidgetValue.number(max).plainText)") }
            return nil
        default:
            return nil
        }
    }

    static func display(_ value: WidgetValue?, field: FormWidget.Field, formatter: WidgetFormatter) -> String {
        switch value {
        case .string(let text)? where !text.isEmpty:
            if field.kind == .choice { return field.options?.first { $0.id == text }?.label ?? text }
            if field.kind == .date { return formatter.date(text) ?? text }
            return text
        case .bool(let on)?: return on ? String(localized: "Yes") : String(localized: "No")
        case .number(let number)?: return WidgetValue.number(number).plainText + (field.unit.map { " \($0)" } ?? "")
        default: return "—"
        }
    }
}

private extension View {
    func well() -> some View {
        padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
    }
}

// MARK: - approval

/// The agent asks permission for a real-world action, with every consequence spelled out and the
/// answers as tiles (`Asking.approval`, `approvalPending`, `approvalDone`, `approvalExpired`,
/// `approvalDraft`, `approvalSpend`).
struct ApprovalBody: View {
    let model: ApprovalWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var editing = false
    @State private var announcedCountdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            subject
            consequences
            if showsTiles { tiles }
        }
        .sheet(isPresented: $editing) {
            ApprovalEditSheet(model: model) { text in
                editing = false
                context.answer(.approval(context.payload, .edit(text)))
            }
        }
        .task(id: context.now) { await announceCountdown() }
    }

    private var showsTiles: Bool {
        switch context.interaction {
        case .resolved, .expired, .readOnly, .superseded: false
        default: true
        }
    }

    // MARK: Subject

    @ViewBuilder
    private var subject: some View {
        let subject = model.subject
        if let change = subject.change {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatter.string(change.from)).font(WidgetFont.value.monospacedDigit()).foregroundStyle(Theme.secondaryText).strikethrough()
                Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                Text(formatter.string(change.to)).font(WidgetFont.amount.monospacedDigit())
                if let label = change.label { Text(label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "\(change.label ?? "") from \(formatter.string(change.from)) to \(formatter.string(change.to))"))
        } else if let amount = subject.amount {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatter.string(amount)).font(WidgetFont.amount.monospacedDigit())
                if let summary = subject.summary { Text(widgetLinking: summary).font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
            }
            .accessibilityElement(children: .combine)
        } else if let summary = subject.summary {
            Text(widgetLinking: summary).font(WidgetFont.body.weight(.semibold))
        }
        if let items = subject.items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(WidgetFont.body)
                            if let detail = item.detail { Text(widgetLinking: detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
                        }
                        Spacer(minLength: 8)
                        if let value = item.value { Text(formatter.string(value)).font(WidgetFont.body.monospacedDigit()) }
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
            }
            .widgetWell(padding: 10)
        }
        if let message = subject.message {
            VStack(alignment: .leading, spacing: 6) {
                Text([String(localized: "To \(message.to.name)"), message.channel, message.address, message.language].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                if let title = message.subject { Text(title).font(WidgetFont.body.weight(.semibold)) }
                // The exact words that would go: invisible and reordering characters show as codes.
                Text(VisibleText.of(message.text)).font(WidgetFont.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let translation = message.translation {
                    Divider().overlay(Theme.hairline)
                    Text(translation).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    Label(attachments.map(\.alt).joined(separator: ", "), systemImage: "paperclip").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            .widgetWell(padding: 12)
        }
    }

    // MARK: Consequences

    private var consequences: some View {
        let consequences = model.consequences
        return VStack(alignment: .leading, spacing: 0) {
            if let cost = consequences.cost {
                let rest = [recurring(cost.recurring), cost.method.map { String(localized: "from \($0)") }].compactMap { $0 }.map { " " + $0 }.joined()
                line("creditcard", Text("\(Text(String(localized: "Pays \(formatter.string(cost.amount))")).fontWeight(.semibold))\(rest)"))
            }
            ForEach(Array(consequences.affects.enumerated()), id: \.offset) { _, affect in
                line("person", Text(affect))
            }
            switch consequences.reversible {
            case .yes:
                line("arrow.uturn.backward", Text(consequences.undoNote ?? String(localized: "Can be undone")))
            case .until:
                let until = consequences.reversibleUntil.flatMap { formatter.time($0) } ?? ""
                line("arrow.uturn.backward", Text("\(Text(String(localized: "Cancel until \(until)")).fontWeight(.semibold)), \(String(localized: "then it's final"))"))
            case .no:
                line("exclamationmark.triangle", Text(String(localized: "Can't be undone")).fontWeight(.semibold))
            }
            if context.payload.envelope.resolution == nil, let expires = context.payload.envelope.expiresAt, let date = WidgetClock.date(expires), date > context.now {
                line("hourglass", Text(String(localized: "Expires at \(formatter.time(expires) ?? expires), \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: context.now))")))
            }
        }
    }

    private func recurring(_ recurring: ApprovalWidget.Consequences.Cost.Recurring) -> String? {
        switch recurring {
        case .once: nil
        case .daily: String(localized: "every day")
        case .weekly: String(localized: "every week")
        case .monthly: String(localized: "every month")
        case .yearly: String(localized: "every year")
        }
    }

    private func line(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 18)
            text.font(WidgetFont.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    /// The countdown is announced once, under two minutes; never every tick.
    private func announceCountdown() async {
        guard voiceOver, !announcedCountdown, let expires = WidgetClock.date(context.payload.envelope.expiresAt) else { return }
        let left = expires.timeIntervalSince(context.now)
        if left > 120 {
            try? await Task.sleep(for: .seconds(left - 120))
            guard !Task.isCancelled else { return }
        }
        guard expires > .now, !announcedCountdown else { return }
        announcedCountdown = true
        AccessibilityNotification.Announcement(String(localized: "\(context.payload.title) expires in under 2 minutes")).post()
    }

    // MARK: Tiles

    private var isDestructive: Bool { model.subject.kind == .delete }

    private var tiles: some View {
        let pending = context.pendingAction
        let approve = ApprovalTile(
            symbol: isDestructive ? "trash" : "checkmark", title: pending == "approve" ? String(localized: "Approving…") : model.subject.verb,
            caption: pending == "approve" ? String(localized: "Sent") : model.answers?.approve,
            style: isDestructive ? .destructive : .primary, isPending: pending == "approve", dims: pending != nil && pending != "approve"
        ) { context.answer(.approval(context.payload, .approve)) }
        let reject = ApprovalTile(
            symbol: "xmark", title: String(localized: "Reject"), caption: model.answers?.reject,
            style: .reject, isPending: pending == "reject", dims: pending != nil && pending != "reject"
        ) { context.answer(.approval(context.payload, .reject(note: nil))) }
        let edit = ApprovalTile(
            symbol: "pencil", title: String(localized: "Edit"), caption: model.answers?.edit,
            style: .neutral, isPending: pending == "edit", dims: pending != nil && pending != "edit"
        ) { editing = true }
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { approve; edit; reject }
            } else {
                VStack(spacing: 8) {
                    approve
                    // Side by side at one height, whichever caption is longer.
                    HStack(spacing: 8) { reject; edit }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(!context.canAnswer)
    }
}

/// One answer tile (`Asking.approval` tiles): the verb in ink, Reject with a red label on a faint
/// red wash, Edit neutral. Each says what it does.
private struct ApprovalTile: View {
    enum Style { case primary, destructive, reject, neutral }

    let symbol: String
    let title: String
    let caption: String?
    let style: Style
    let isPending: Bool
    let dims: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                if isPending {
                    PendingGlyph(color: style == .primary ? Theme.inkForeground : Theme.secondaryText)
                } else {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(WidgetFont.body.weight(.semibold))
                if let caption { Text(caption).font(WidgetFont.caption).opacity(0.8).multilineTextAlignment(.leading) }
            }
            .foregroundStyle(foreground)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 82, maxHeight: .infinity, alignment: .topLeading)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if style == .reject {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.dangerBorder)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .opacity(dims ? 0.45 : 1)
        .accessibilityLabel([title, caption].compactMap { $0 }.joined(separator: ", "))
    }

    private var foreground: Color {
        switch style {
        case .primary: Theme.inkForeground
        case .destructive, .reject: Theme.danger
        case .neutral: Theme.primaryText
        }
    }

    private var background: Color {
        switch style {
        case .primary: Theme.ink
        case .destructive: Theme.controlFill
        case .reject: Theme.dangerWash
        case .neutral: Theme.canvas
        }
    }
}

/// Edit: the subject's words prefilled for a message; for anything else, what should change.
private struct ApprovalEditSheet: View {
    let model: ApprovalWidget
    let send: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(model.subject.message == nil ? String(localized: "What should change?") : "", text: $text, axis: .vertical)
                        .lineLimit(4...14)
                } footer: {
                    Text(model.subject.message == nil ? String(localized: "Hermes changes the request and asks you again.") : String(localized: "Hermes sends the new version back for your OK."))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.subject.message == nil ? String(localized: "Edit Request") : String(localized: "Edit Message"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(text) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { if text.isEmpty { text = model.subject.message?.text ?? "" } }
        #if os(macOS)
        .frame(width: 460, height: 360)
        #endif
    }
}

// MARK: - receipt

/// Proof that something was done, with Undo while it's possible (`Asking.receipt`,
/// `receiptUndone`).
struct ReceiptBody: View {
    let model: ReceiptWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @State private var confirmsUndo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let undone = model.undone {
                hero(symbol: "arrow.uturn.backward.circle.fill", color: Theme.secondaryText, headline: undone.headline,
                     detail: [undone.detail, undone.refund.map { refund in
                         [String(localized: "\(formatter.string(refund.amount)) back"), refund.to.map { String(localized: "to \($0)") }, refund.when].compactMap { $0 }.joined(separator: " ")
                     }].compactMap { $0 }.joined(separator: " · "))
            } else {
                hero(symbol: "checkmark.circle.fill", color: Theme.success, headline: model.headline, detail: model.detail)
                facts
                undoBar
            }
            EvidenceLine(evidence: model.confirmation)
            if let note = model.note { Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
        }
        .confirmationDialog(model.undo?.note ?? "", isPresented: $confirmsUndo, titleVisibility: .visible) {
            Button("Undo", role: .destructive) { context.answer(.plain(context.payload, "undo")) }
        }
    }

    private func hero(symbol: String, color: Color, headline: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(WidgetFont.value.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty { Text(widgetLinking: detail).font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var facts: some View {
        if let facts = model.facts, !facts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(facts.prefix(6).enumerated()), id: \.offset) { index, fact in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    let value = formatter.string(fact.value)
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.label).font(WidgetFont.body).foregroundStyle(Theme.secondaryText)
                        Spacer(minLength: 8)
                        // The value and its detail on one line ("€14.50 · Visa •• 4242", `Asking.receipt`).
                        Text([value, fact.detail].compactMap { $0 }.joined(separator: " · "))
                            .font(WidgetFont.body.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                        if fact.copy {
                            Button { context.copy(value) } label: {
                                Image(systemName: "square.on.square").font(.system(size: 11)).frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityLabel(String(localized: "Copy \(fact.label)"))
                        }
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var undoBar: some View {
        if let undo = model.undo, context.interaction != .resolved {
            let open = undo.until.flatMap(WidgetClock.date).map { $0 > context.now } ?? true
            if open {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold))
                    Text(context.pendingAction == "undo" ? String(localized: "Undoing…") : (undo.note.map { _ in undo.label } ?? undo.label))
                        .font(WidgetFont.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button {
                        if undo.note != nil { confirmsUndo = true } else { context.answer(.plain(context.payload, "undo")) }
                    } label: {
                        HStack(spacing: 4) {
                            if context.pendingAction == "undo" { PendingGlyph() }
                            Text("Undo").font(WidgetFont.label.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .background(Theme.controlFill, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.primaryText)
                    .frame(minHeight: 44)
                    .disabled(!context.canAnswer)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let until = undo.until.flatMap({ formatter.time($0) }) {
                Text("Final since \(until)").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - control

/// Live controls for one smart-home device: every change is a request shown pending until the
/// device reports back (`Asking.control`, `controlPending`, `controlThermostat`).
struct ControlBody: View {
    let model: HermesKit.ControlWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    /// Slider and stepper values while they move; one `set` goes 300 ms after the last change.
    @State private var dragging: [String: Double] = [:]
    @State private var debounce: Task<Void, Never>?

    private var pendingControl: (id: String, value: JSONValue)? {
        guard let values = context.pendingValues, let id = values["control"]?.stringValue, let value = values["value"] else { return nil }
        return (id, value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.device.reachable {
                WidgetBanner(tone: .unverified, symbol: "questionmark.circle.fill",
                             text: [String(localized: "\(model.device.name) isn't responding"), model.device.status].compactMap { $0 }.joined(separator: " · "))
            }
            deviceRow
            ForEach(Array(model.controls.enumerated()), id: \.offset) { index, control in
                if !(index == 0 && control.kind == .switch && model.device.name != context.payload.title) {
                    controlView(control)
                }
            }
        }
        .disabled(!model.device.reachable || !context.canAnswer)
    }

    @ViewBuilder
    private var deviceRow: some View {
        let first = model.controls.first { $0.kind == .switch }
        HStack(spacing: 10) {
            WidgetGlyph(name: model.device.symbol, fallback: "lightbulb.fill", size: 16, color: model.device.active ? Theme.warning : Theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.device.name).font(WidgetFont.body.weight(.semibold))
                Text([model.device.status, model.device.room].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            if let first, model.device.name != context.payload.title { switchView(first, labelled: false) }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func controlView(_ control: HermesKit.ControlWidget.Control) -> some View {
        switch control.kind {
        case .switch: switchView(control, labelled: true)
        case .slider: slider(control)
        case .stepper: stepper(control)
        case .scenes: scenes(control)
        case .segmented: segmented(control)
        }
    }

    private func isPending(_ control: HermesKit.ControlWidget.Control) -> Bool {
        pendingControl?.id == control.id
    }

    /// What a control shows: a move in progress, the change waiting on the device, else what the
    /// device last reported.
    private func shown(_ control: HermesKit.ControlWidget.Control) -> WidgetValue? {
        if let moving = dragging[control.id] { return .number(moving) }
        if let pending = pendingControl, pending.id == control.id {
            switch pending.value {
            case .number(let number): return .number(number)
            case .bool(let on): return .bool(on)
            case .string(let text): return .string(text)
            default: return nil
            }
        }
        return control.value
    }

    private func set(_ control: HermesKit.ControlWidget.Control, _ value: WidgetValue) {
        context.answer(.control(context.payload, model, control: control.id, value: value))
    }

    private func pendingNote(_ control: HermesKit.ControlWidget.Control) -> some View {
        Group {
            if isPending(control) {
                HStack(spacing: 4) {
                    PendingGlyph()
                    Text("Setting \(display(control, shown(control)))…")
                }
                .font(WidgetFont.caption)
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func display(_ control: HermesKit.ControlWidget.Control, _ value: WidgetValue?) -> String {
        switch value {
        case .bool(let on)?: on ? String(localized: "on") : String(localized: "off")
        case .number(let number)?: WidgetValue.number(number).plainText + (control.unit.map { $0 == "%" || $0.hasPrefix("°") ? $0 : " \($0)" } ?? "")
        case .string(let id)?: control.options?.first { $0.id == id }?.label ?? id
        default: WidgetFormatter.unknown
        }
    }

    private func switchView(_ control: HermesKit.ControlWidget.Control, labelled: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Toggle(isOn: Binding(get: { shown(control)?.bool ?? false }, set: { set(control, .bool($0)) })) {
                if labelled { Text(control.label).font(WidgetFont.body).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .labelsHidden(!labelled)
            .toggleStyle(.switch)
            .tint(Theme.success)
            .opacity(isPending(control) ? 0.5 : 1)
            .accessibilityLabel(control.label)
            pendingNote(control)
        }
    }

    private func slider(_ control: HermesKit.ControlWidget.Control) -> some View {
        let range = control.sliderRange
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(control.label).font(WidgetFont.body)
                Spacer()
                Text(display(control, shown(control))).font(WidgetFont.body.monospacedDigit())
                    .foregroundStyle(isPending(control) ? Theme.secondaryText : Theme.primaryText)
            }
            WidgetBarSlider(value: Binding(get: { shown(control)?.number ?? range.lowerBound }, set: { moving in
                dragging[control.id] = moving
                debounce?.cancel()
                debounce = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    dragging[control.id] = nil
                    set(control, .number(moving))
                }
            }), range: range, step: control.step(default: 1))
            .opacity(isPending(control) ? 0.5 : 1)
            .accessibilityLabel(control.label)
            .accessibilityValue(display(control, shown(control)))
            pendingNote(control)
        }
    }

    private func stepper(_ control: HermesKit.ControlWidget.Control) -> some View {
        let step = control.step(default: 0.5)
        let current = shown(control)?.number
        return VStack(spacing: 6) {
            HStack(spacing: 18) {
                stepButton("minus", control: control, to: (current ?? control.min ?? 0) - step)
                Text(display(control, shown(control)))
                    .font(WidgetFont.valueHero.monospacedDigit())
                    .foregroundStyle(isPending(control) ? Theme.secondaryText : Theme.primaryText)
                    .contentTransition(.numericText())
                stepButton("plus", control: control, to: (current ?? control.min ?? 0) + step)
            }
            .frame(maxWidth: .infinity)
            if let reading = control.reading {
                Text(String(localized: "Now \(formatter.string(reading))") + (model.device.status.map { " · \($0)" } ?? ""))
                    .font(WidgetFont.label)
                    .foregroundStyle(model.device.active ? Theme.warning : Theme.secondaryText)
            }
            pendingNote(control)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(control.label)
        .accessibilityValue(display(control, shown(control)))
        .accessibilityAdjustableAction { direction in
            let base = current ?? control.min ?? 0
            nudge(control, to: direction == .increment ? base + step : base - step)
        }
    }

    private func stepButton(_ symbol: String, control: HermesKit.ControlWidget.Control, to value: Double) -> some View {
        Button { nudge(control, to: value) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Theme.controlFill, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(control.min.map { value < $0 } == true || control.max.map { value > $0 } == true)
    }

    private func nudge(_ control: HermesKit.ControlWidget.Control, to value: Double) {
        let clamped = min(max(value, control.min ?? -.infinity), control.max ?? .infinity)
        dragging[control.id] = clamped
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            dragging[control.id] = nil
            set(control, .number(clamped))
        }
    }

    private func scenes(_ control: HermesKit.ControlWidget.Control) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(max(control.options?.count ?? 1, 1), 4)), spacing: 6) {
            ForEach(control.options ?? [], id: \.id) { option in
                let active = shown(control)?.string == option.id
                Button { set(control, .string(option.id)) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: WidgetSymbols.resolve(option.symbol) ?? "sparkles").font(.system(size: 15))
                        Text(option.label).font(WidgetFont.caption.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(active ? Theme.inkForeground : Theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(active ? Theme.ink : Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                    .opacity(isPending(control) && active ? 0.6 : 1)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    private func segmented(_ control: HermesKit.ControlWidget.Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(control.label, selection: Binding(get: { shown(control)?.string ?? "" }, set: { set(control, .string($0)) })) {
                ForEach(control.options ?? [], id: \.id) { option in Text(option.label).tag(option.id) }
            }
            .pickerStyle(.segmented)
            .opacity(isPending(control) ? 0.6 : 1)
            pendingNote(control)
        }
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// `Asking.control`'s slider: a thick capsule filled in ink up to the value, set by dragging or
/// tapping anywhere along it. VoiceOver adjusts it as a slider.
struct WidgetBarSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { proxy in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.controlFill)
                Capsule().fill(Theme.ink).frame(width: max(28, proxy.size.width * fraction))
            }
            .environment(\.layoutDirection, .leftToRight)
            .contentShape(Capsule())
            .gesture(SpatialTapGesture().onEnded { move(to: $0.location.x, width: proxy.size.width) })
            #if os(iOS)
            .gesture(SidewaysPan { move(to: $0, width: proxy.size.width) })
            #else
            .gesture(DragGesture(minimumDistance: 0).onChanged { move(to: $0.location.x, width: proxy.size.width) })
            #endif
        }
        .frame(height: 28)
        // Arrow keys move it a twentieth of the way, as a slider does with the keyboard.
        .focusable()
        .onKeyPress(.leftArrow) { nudge(-1) }
        .onKeyPress(.rightArrow) { nudge(1) }
        .onKeyPress(.downArrow) { nudge(-1) }
        .onKeyPress(.upArrow) { nudge(1) }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step)
        }
    }

    private func nudge(_ direction: Double) -> KeyPress.Result {
        let span = range.upperBound - range.lowerBound
        let amount = step > 0 ? max(step, (span / 20 / step).rounded() * step) : span / 20
        value = min(max(value + direction * amount, range.lowerBound), range.upperBound)
        return .handled
    }

    private func move(to x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let fraction = min(max(x / width, 0), 1)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        let stepped = step > 0 ? (raw / step).rounded() * step : raw
        let next = min(max(stepped, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }
}

#if os(iOS)
/// A pan that starts only when the finger moves sideways, so a chat still scrolls over a slider
/// (a SwiftUI drag on a scrolling row takes the scroll).
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        changed(context.converter.localLocation.x)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
#endif
