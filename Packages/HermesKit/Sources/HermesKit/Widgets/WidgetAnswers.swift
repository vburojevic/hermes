import Foundation

/// The built-in answers (contract §6.1): each primitive's action id, its `values`, and the words
/// line 1 shows, built from the labels the person saw.
public extension WidgetAnswer {
    /// `choice` → `answer`: `{selected: [option ids], other?: text}`.
    static func choice(_ payload: WidgetPayload, _ widget: ChoiceWidget, selected: [String], other: String? = nil) -> WidgetAnswer {
        let labels = selected.compactMap { id in widget.options.first { $0.id == id }?.label }
        var words = labels.joined(separator: ", ")
        var values: [String: JSONValue] = ["selected": .array(selected.map(JSONValue.string))]
        if let other = other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
            values["other"] = .string(other)
            words += (words.isEmpty ? "" : ", ") + defuse(other)
        }
        return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "answer", words: words.isEmpty ? nil : words, values: .object(values))
    }

    /// `checklist` → `check`: `{checked: [ids], unchecked: [ids]}`, the batch of ticks since the
    /// last message.
    static func checklist(_ payload: WidgetPayload, _ widget: ChecklistWidget, checked: [String], unchecked: [String]) -> WidgetAnswer {
        func labels(_ ids: [String]) -> String {
            ids.compactMap { id in widget.items.first { $0.id == id }?.label }.joined(separator: ", ")
        }
        var parts: [String] = []
        if !checked.isEmpty { parts.append("check: \(labels(checked))") }
        if !unchecked.isEmpty { parts.append("uncheck: \(labels(unchecked))") }
        // The words lead with their own verb ("check: Tomatoes · uncheck: Milk").
        let words = parts.joined(separator: " · ").dropFirst(checked.isEmpty ? 0 : "check: ".count)
        return WidgetAnswer(
            widgetID: payload.id, rev: payload.rev, action: "check", words: words.isEmpty ? nil : String(words),
            values: .object(["checked": .array(checked.map(JSONValue.string)), "unchecked": .array(unchecked.map(JSONValue.string))])
        )
    }

    /// `form` → `submit`: `{<field id>: value}`. Free text is defused on line 1.
    static func form(_ payload: WidgetPayload, _ widget: FormWidget, values: [String: WidgetValue]) -> WidgetAnswer {
        let words = widget.fields.map { field -> String in
            let value = values[field.id] ?? .null
            let shown: String
            switch (field.kind, value) {
            case (_, .null): shown = "—"
            case (.text, .string(let text)), (.longText, .string(let text)): shown = text.isEmpty ? "—" : defuse(text)
            case (.choice, .string(let id)): shown = field.options?.first { $0.id == id }?.label ?? id
            case (_, .bool(let on)): shown = on ? "yes" : "no"
            case (_, .number(let number)): shown = WidgetValue.number(number).plainText
            case (_, .string(let text)): shown = text.isEmpty ? "—" : defuse(text)
            }
            return "\(field.label): \(shown)"
        }.joined(separator: "; ")
        var object: [String: JSONValue] = [:]
        for (key, value) in values { object[key] = value.json }
        return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "submit", words: words, values: .object(object))
    }

    /// `form` → `cancel`.
    static func cancelForm(_ payload: WidgetPayload) -> WidgetAnswer {
        WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "cancel")
    }

    /// `control` → `set`: `{control: id, value}`.
    static func control(_ payload: WidgetPayload, _ widget: ControlWidget, control id: String, value: WidgetValue) -> WidgetAnswer {
        let control = widget.controls.first { $0.id == id }
        let shown: String
        switch value {
        case .bool(let on): shown = on ? "on" : "off"
        case .string(let option): shown = control?.options?.first { $0.id == option }?.label ?? option
        case .number(let number): shown = WidgetValue.number(number).plainText + (control?.unit.map { $0 == "%" ? $0 : " \($0)" } ?? "")
        case .null: shown = "—"
        }
        return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "set", words: "\(control?.label ?? id): \(shown)",
                            values: .object(["control": .string(id), "value": value.json]))
    }

    enum ApprovalChoice: Hashable, Sendable {
        case approve
        case edit(String)
        case reject(note: String?)
    }

    /// `approval` → `approve`, `edit` (`{text}`) or `reject` (`{note?}`).
    static func approval(_ payload: WidgetPayload, _ choice: ApprovalChoice) -> WidgetAnswer {
        switch choice {
        case .approve:
            return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "approve")
        case .edit(let text):
            return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "edit", words: defuse(text), values: .object(["text": .string(text)]))
        case .reject(let note):
            guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
                return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "reject")
            }
            return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "reject", words: defuse(note), values: .object(["note": .string(note)]))
        }
    }

    enum Rating: String, CaseIterable, Sendable { case again, hard, good, easy }

    /// `flashcard` → `rate`: `{ratings: [{card, rating}]}`, one message for the session.
    static func flashcards(_ payload: WidgetPayload, ratings: [(card: String, rating: Rating)]) -> WidgetAnswer {
        let counts = Rating.allCases.reversed().compactMap { rating -> String? in
            let count = ratings.filter { $0.rating == rating }.count
            return count == 0 ? nil : "\(count) \(rating.rawValue)"
        }
        let words = "\(ratings.count) card\(ratings.count == 1 ? "" : "s") · " + counts.joined(separator: ", ")
        let values = JSONValue.object(["ratings": .array(ratings.map { .object(["card": .string($0.card), "rating": .string($0.rating.rawValue)]) })])
        return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "rate", words: words, values: values)
    }

    /// `compare` → `answer`: `{option: id, weights?: {criterion id: 0–5}}`.
    static func compare(_ payload: WidgetPayload, _ widget: CompareWidget, option: String, weights: [String: Int]? = nil) -> WidgetAnswer {
        var values: [String: JSONValue] = ["option": .string(option)]
        if let weights, !weights.isEmpty { values["weights"] = .object(weights.mapValues { .number(Double($0)) }) }
        let name = widget.options.first { $0.id == option }?.name ?? option
        return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "answer",
                            words: weights?.isEmpty == false ? "\(name) (my weights)" : name, values: .object(values))
    }

    /// An answer without values: `acknowledge` (alert), `undo` (receipt, or a resolution's undo),
    /// `refresh`, `retry` (a failed resolution).
    static func plain(_ payload: WidgetPayload, _ action: String) -> WidgetAnswer {
        WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: action)
    }

    /// A payload's own `reply` action: a widget-level button (with the guide's step on screen),
    /// or a row's (`{item}`), with the action's opaque payload echoed.
    static func custom(_ payload: WidgetPayload, _ action: WidgetAction, item: (id: String, title: String)? = nil, step: String? = nil) -> WidgetAnswer {
        var values: [String: JSONValue] = [:]
        if let item { values["item"] = .string(item.id) }
        if let step { values["step"] = .string(step) }
        return WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: action.id,
                            words: item.map { $0.title }, values: .object(values), echo: action.payload)
    }
}

public extension WidgetValue {
    /// The value as plain text, numbers without a needless ".0".
    var plainText: String {
        switch self {
        case .number(let number):
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .string(let text): text
        case .bool(let on): on ? "true" : "false"
        case .null: "—"
        }
    }
}
