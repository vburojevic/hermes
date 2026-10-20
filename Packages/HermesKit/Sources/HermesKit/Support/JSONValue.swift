import Foundation

/// Any JSON value, for payloads whose shape the server keeps open (tool args, extras).
public enum JSONValue: Hashable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// The number (or numeric string) as an Int, cut toward zero like `Int(_:)`, or nil when it's
    /// not finite or doesn't fit. Gateway and model JSON can carry `1e300` or `"nan"`, on which
    /// `Int(_:)` stops the app (security scan F3, F14).
    public var truncatedIntValue: Int? {
        doubleValue.flatMap(Int.init(checking:))
    }

    /// A compact, human-readable rendering for previews.
    public var displayText: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .array, .object:
            (try? String(decoding: JSONEncoder.sortedCompact.encode(self), as: UTF8.self)) ?? ""
        }
    }

    /// Parses a JSON document held in a string, as tool-call `arguments` are.
    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// Parses JSON in one pass over Foundation's parser. `init(from:)` tries each type in turn and
    /// throws a `DecodingError` for every miss — a few per value — which every socket frame, tool
    /// result and graph paid for.
    public static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(foundation: object)
    }

    /// `parse(_:)` for callers that throw: a `DecodingError` when the data isn't JSON.
    public static func decode(_ data: Data) throws -> JSONValue {
        guard let value = parse(data) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "The data isn't valid JSON."))
        }
        return value
    }

    /// A value from `JSONSerialization`'s output. Booleans arrive as `NSNumber`s too; their
    /// CoreFoundation type tells them apart from numbers.
    init(foundation value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }
}

extension JSONEncoder {
    static let sortedCompact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// Lenient date parsing for the two encodings Hermes uses: epoch seconds and ISO 8601.
public enum HermesDate {
    public static func fromEpoch(_ seconds: Double?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Parses Python `isoformat()` output, which may carry microseconds and an offset.
    public static func fromISO(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        // Normalise fractional seconds to milliseconds; ISO8601DateFormatter is strict about them.
        if let dot = text.firstIndex(of: "."), let timeStart = text.firstIndex(of: "T"), dot > timeStart {
            let digitsEnd = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<digitsEnd]
            let millis = String((digits + "000").prefix(3))
            text.replaceSubrange(dot..<digitsEnd, with: "." + millis)
        }
        if !text.contains("Z"), !hasOffset(text) {
            text += "Z" // naive timestamps are UTC on the server
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func hasOffset(_ text: String) -> Bool {
        guard let timeStart = text.firstIndex(of: "T") else { return false }
        let time = text[timeStart...]
        return time.contains("+") || time.dropFirst().contains("-")
    }
}

extension Int {
    /// `Int(value)` without the trap: nil for NaN, infinity and anything outside Int's range.
    public init?(checking value: Double) {
        guard value.isFinite, value >= -0x1p63, value < 0x1p63 else { return nil }
        self.init(value)
    }
}

extension Int {
    /// `Int(value)` held to Int's range (NaN reads as 0): for times and counts that are only shown,
    /// where a wild value from the gateway shouldn't stop the app.
    public init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= 0x1p63 {
            self = .max
        } else if value < -0x1p63 {
            self = .min
        } else {
            self.init(value)
        }
    }
}

extension Int64 {
    /// `Int64(value)` without the trap: nil for NaN, infinity and anything outside Int64's range.
    public init?(checking value: Double) {
        guard value.isFinite, value >= -0x1p63, value < 0x1p63 else { return nil }
        self.init(value)
    }
}
