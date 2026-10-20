import Foundation

/// A value the schemas allow in more than one JSON type: a number, text or a switch (a
/// `Quantity`'s raw value, a control's value, a form answer).
public enum WidgetValue: Decodable, Hashable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var json: JSONValue {
        switch self {
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        case .null: .null
        }
    }
}

/// A labelled value that is either words or a formatted quantity (a details field, a diff's
/// before and after, a compare cell).
public enum WidgetFieldValue: Decodable, Hashable, Sendable {
    case text(String)
    case quantity(WidgetQuantity)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .quantity(try container.decode(WidgetQuantity.self))
        }
    }
}

/// One table cell: a raw value (`null` for unknown), or a value with a pre-formatted display
/// and a state drawn as a tag.
public struct WidgetCell: Decodable, Hashable, Sendable {
    public var value: WidgetValue?
    public var display: String?
    public var state: WidgetTag.State?

    enum CodingKeys: String, CodingKey {
        case value, display, state
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            value = try keyed.decodeIfPresent(WidgetValue.self, forKey: .value)
            display = try keyed.decodeIfPresent(String.self, forKey: .display)
            state = try keyed.decodeIfPresent(WidgetTag.State.self, forKey: .state)
        } else {
            let raw = try WidgetValue(from: decoder)
            value = raw == .null ? nil : raw
        }
    }
}

extension WidgetQuantity {
    /// A quantity the app builds itself (a chart's scrubbed value, what's left of a budget).
    public init(value: WidgetValue?, format: Format = .number, unit: String? = nil, currency: String? = nil,
                precision: Int? = nil, display: String? = nil) {
        self.value = value
        self.format = format
        self.unit = unit
        self.currency = currency
        self.precision = precision
        self.display = display
    }
}

extension WidgetTag {
    /// A tag the app draws itself ("New", a table cell's state).
    public init(label: String, state: State = .neutral) {
        self.label = label
        self.state = state
    }
}

extension WidgetDelta {
    /// A change the app builds itself (a table's change column).
    public init(value: Double, format: Format = .percent, currency: String? = nil, good: Good, period: String? = nil) {
        self.value = value
        self.format = format
        self.currency = currency
        self.good = good
        self.period = period
    }
}

/// A widget inside a stack: drawn, or shown as its own text when this app can't draw its type
/// (an unknown type or a newer major version). One such child doesn't sink the stack.
public enum WidgetStackChild: Decodable, Hashable, Sendable {
    case payload(WidgetPayload)
    case unreadable(JSONValue)

    public init(from decoder: any Decoder) throws {
        if let payload = try? WidgetPayload(from: decoder) {
            self = .payload(payload)
        } else {
            self = .unreadable(try JSONValue(from: decoder))
        }
    }

    public var payload: WidgetPayload? {
        if case .payload(let payload) = self { payload } else { nil }
    }

    public var id: String? {
        switch self {
        case .payload(let payload): payload.id
        case .unreadable(let json): json["id"]?.stringValue
        }
    }
}
