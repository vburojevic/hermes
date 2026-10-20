import Foundation

/// A JSON Schema 2020-12 validator for the widget schemas (`docs/widgets.md` §3).
///
/// It covers every keyword the widget schemas use: `$ref` across documents, the applicators
/// (`allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, `dependentSchemas`), annotations for
/// `unevaluatedProperties`, the array, object, string and number assertions, and the `date`,
/// `date-time` and `email` formats as assertions, as the producer's validator checks them.
public struct JSONSchemaValidator: Sendable {
    /// One reason an instance doesn't match.
    public struct Failure: Hashable, Sendable, CustomStringConvertible {
        /// Where in the instance: property names and array indices.
        public var path: [PathComponent]
        /// The keyword that failed (`required`, `enum`, `unevaluatedProperties`…).
        public var keyword: String
        public var message: String
        /// For `anyOf` and `oneOf` failures: what each branch said.
        public var causes: [Failure] = []
        /// For `additionalProperties` and `unevaluatedProperties`: the property that wasn't allowed.
        public var property: String?
        /// For `enum`: the values the schema allows there.
        public var allowed: [JSONValue]?

        public enum PathComponent: Hashable, Sendable {
            case key(String)
            case index(Int)
        }

        /// `items[0].delta.good`, or `(root)`.
        public var location: String {
            Self.location(path)
        }

        public static func location(_ path: [PathComponent]) -> String {
            var text = ""
            for component in path {
                switch component {
                case .key(let key): text += text.isEmpty ? key : ".\(key)"
                case .index(let index): text += "[\(index)]"
                }
            }
            return text.isEmpty ? "(root)" : text
        }

        public var description: String { "\(location): \(message)" }
    }

    private let documents: [String: JSONValue]
    private let patterns: RegexCache

    /// - Parameter documents: Schemas with an absolute `$id`; `$ref`s resolve between them.
    public init(documents: [JSONValue]) {
        var byID: [String: JSONValue] = [:]
        for document in documents {
            if let id = document["$id"]?.stringValue { byID[Self.stripFragment(id)] = document }
        }
        self.documents = byID
        var found: Set<String> = []
        for document in documents { Self.collectPatterns(document, into: &found) }
        patterns = RegexCache(patterns: found)
    }

    /// Validates `instance` against the schema whose `$id` is `schemaID`.
    public func validate(_ instance: JSONValue, schemaID: String) -> [Failure] {
        guard let schema = documents[Self.stripFragment(schemaID)] else {
            return [Failure(path: [], keyword: "$ref", message: "no schema \(schemaID)")]
        }
        return evaluate(instance, schema: schema, path: [], base: Self.stripFragment(schemaID)).failures
    }

    // MARK: - Evaluation

    private struct Outcome {
        var failures: [Failure] = []
        /// Properties of the instance at this location that a successful keyword evaluated.
        var evaluated: Set<String> = []
        var isValid: Bool { failures.isEmpty }

        mutating func fail(_ path: [Failure.PathComponent], _ keyword: String, _ message: String, causes: [Failure] = [], property: String? = nil) {
            failures.append(Failure(path: path, keyword: keyword, message: message, causes: causes, property: property))
        }

        /// Takes a subschema's failures, and its annotations when it passed.
        mutating func absorb(_ other: Outcome) {
            failures += other.failures
            if other.isValid { evaluated.formUnion(other.evaluated) }
        }
    }

    private func evaluate(_ instance: JSONValue, schema: JSONValue, path: [Failure.PathComponent], base: String) -> Outcome {
        var outcome = Outcome()
        switch schema {
        case .bool(true):
            return outcome
        case .bool(false):
            outcome.fail(path, "false", "False schema does not allow \(Self.short(instance))")
            return outcome
        case .object:
            break
        default:
            return outcome
        }
        let base = schema["$id"]?.stringValue.map(Self.stripFragment) ?? base

        if let ref = schema["$ref"]?.stringValue {
            if let (target, targetBase) = resolve(ref, base: base) {
                outcome.absorb(evaluate(instance, schema: target, path: path, base: targetBase))
            } else {
                outcome.fail(path, "$ref", "can't resolve \(ref)")
            }
        }
        checkType(instance, schema, path, &outcome)
        if let values = schema["enum"]?.arrayValue, !values.contains(where: { Self.equal($0, instance) }) {
            outcome.fail(path, "enum", "\(Self.short(instance)) is not one of \(Self.list(values))")
            outcome.failures[outcome.failures.count - 1].allowed = values
        }
        if let constant = schema["const"], !Self.equal(constant, instance) {
            outcome.fail(path, "const", "\(Self.short(constant)) was expected")
        }
        switch instance {
        case .string(let text): checkString(text, schema, path, &outcome)
        case .number(let number): checkNumber(number, schema, path, &outcome)
        case .array(let items): checkArray(items, schema, path, base, &outcome)
        case .object(let object): checkObject(object, schema, path, base, &outcome)
        default: break
        }
        applyCombinators(instance, schema, path, base, &outcome)
        if case .object(let object) = instance, let unevaluated = schema["unevaluatedProperties"] {
            for key in object.keys.sorted() where !outcome.evaluated.contains(key) {
                if case .bool(false) = unevaluated {
                    outcome.fail(path, "unevaluatedProperties", "Unevaluated properties are not allowed ('\(key)' was unexpected)", property: key)
                } else {
                    let child = evaluate(object[key]!, schema: unevaluated, path: path + [.key(key)], base: base)
                    outcome.failures += child.failures
                }
                outcome.evaluated.insert(key)
            }
        }
        return outcome
    }

    private func checkType(_ instance: JSONValue, _ schema: JSONValue, _ path: [Failure.PathComponent], _ outcome: inout Outcome) {
        let types: [String]
        switch schema["type"] {
        case .string(let type)?: types = [type]
        case .array(let list)?: types = list.compactMap(\.stringValue)
        default: return
        }
        guard !types.contains(where: { Self.matches(instance, type: $0) }) else { return }
        let expected = types.count == 1 ? "'\(types[0])'" : types.map { "'\($0)'" }.joined(separator: ", ")
        outcome.fail(path, "type", "\(Self.short(instance)) is not of type \(expected)")
    }

    private func checkString(_ text: String, _ schema: JSONValue, _ path: [Failure.PathComponent], _ outcome: inout Outcome) {
        let length = text.unicodeScalars.count
        if let max = schema["maxLength"]?.intValue, length > max {
            outcome.fail(path, "maxLength", "'\(Self.clip(text))' is too long (\(length) > \(max))")
        }
        if let min = schema["minLength"]?.intValue, length < min {
            outcome.fail(path, "minLength", min == 1 ? "'\(text)' should be non-empty" : "'\(text)' is too short")
        }
        if let pattern = schema["pattern"]?.stringValue, !patterns.matches(pattern, text) {
            outcome.fail(path, "pattern", "'\(Self.clip(text))' does not match '\(pattern)'")
        }
        if let format = schema["format"]?.stringValue, !Self.matchesFormat(format, text) {
            outcome.fail(path, "format", "'\(Self.clip(text))' is not a '\(format)'")
        }
    }

    private func checkNumber(_ number: Double, _ schema: JSONValue, _ path: [Failure.PathComponent], _ outcome: inout Outcome) {
        if let minimum = schema["minimum"]?.doubleValue, number < minimum {
            outcome.fail(path, "minimum", "\(Self.format(number)) is less than the minimum of \(Self.format(minimum))")
        }
        if let maximum = schema["maximum"]?.doubleValue, number > maximum {
            outcome.fail(path, "maximum", "\(Self.format(number)) is greater than the maximum of \(Self.format(maximum))")
        }
        if let minimum = schema["exclusiveMinimum"]?.doubleValue, number <= minimum {
            outcome.fail(path, "exclusiveMinimum", "\(Self.format(number)) is less than or equal to the minimum of \(Self.format(minimum))")
        }
        if let maximum = schema["exclusiveMaximum"]?.doubleValue, number >= maximum {
            outcome.fail(path, "exclusiveMaximum", "\(Self.format(number)) is greater than or equal to the maximum of \(Self.format(maximum))")
        }
        if let step = schema["multipleOf"]?.doubleValue, step > 0 {
            let quotient = number / step
            if abs(quotient - quotient.rounded()) > 1e-9 {
                outcome.fail(path, "multipleOf", "\(Self.format(number)) is not a multiple of \(Self.format(step))")
            }
        }
    }

    private func checkArray(_ items: [JSONValue], _ schema: JSONValue, _ path: [Failure.PathComponent], _ base: String, _ outcome: inout Outcome) {
        if let max = schema["maxItems"]?.intValue, items.count > max {
            outcome.fail(path, "maxItems", "\(Self.short(.array(items))) is too long")
        }
        if let min = schema["minItems"]?.intValue, items.count < min {
            outcome.fail(path, "minItems", min == 1 ? "\(Self.short(.array(items))) should be non-empty" : "\(Self.short(.array(items))) is too short")
        }
        var start = 0
        if let prefix = schema["prefixItems"]?.arrayValue {
            for (index, item) in items.enumerated() where index < prefix.count {
                outcome.failures += evaluate(item, schema: prefix[index], path: path + [.index(index)], base: base).failures
            }
            start = prefix.count
        }
        if let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() where index >= start {
                outcome.failures += evaluate(item, schema: itemSchema, path: path + [.index(index)], base: base).failures
            }
        }
        if schema["uniqueItems"]?.boolValue == true {
            for index in items.indices where items[..<index].contains(where: { Self.equal($0, items[index]) }) {
                outcome.fail(path, "uniqueItems", "\(Self.short(.array(items))) has non-unique elements")
                break
            }
        }
        if let contains = schema["contains"] {
            let matching = items.indices.filter { index in
                evaluate(items[index], schema: contains, path: path + [.index(index)], base: base).isValid
            }.count
            let minimum = schema["minContains"]?.intValue ?? 1
            if matching < minimum {
                outcome.fail(path, "contains", minimum <= 1 && schema["minContains"] == nil
                    ? "\(Self.short(.array(items))) does not contain items matching the given schema"
                    : "Too few items match the given schema (expected at least \(minimum) but only \(matching) matched)")
            }
            if let maximum = schema["maxContains"]?.intValue, matching > maximum {
                outcome.fail(path, "maxContains", "Too many items match the given schema (expected at most \(maximum))")
            }
        }
    }

    private func checkObject(_ object: [String: JSONValue], _ schema: JSONValue, _ path: [Failure.PathComponent], _ base: String, _ outcome: inout Outcome) {
        if let required = schema["required"]?.arrayValue {
            for key in required.compactMap(\.stringValue) where object[key] == nil {
                outcome.fail(path, "required", "'\(key)' is a required property")
            }
        }
        if let max = schema["maxProperties"]?.intValue, object.count > max {
            outcome.fail(path, "maxProperties", "\(Self.short(.object(object))) has too many properties")
        }
        if let min = schema["minProperties"]?.intValue, object.count < min {
            outcome.fail(path, "minProperties", "\(Self.short(.object(object))) does not have enough properties")
        }
        if let names = schema["propertyNames"] {
            for key in object.keys.sorted() {
                for failure in evaluate(.string(key), schema: names, path: path, base: base).failures {
                    outcome.fail(path, "propertyNames", "property name \(failure.message)")
                }
            }
        }
        if case .object(let dependencies)? = schema["dependentRequired"] {
            for (key, needs) in dependencies.sorted(by: { $0.key < $1.key }) where object[key] != nil {
                for need in needs.arrayValue?.compactMap(\.stringValue) ?? [] where object[need] == nil {
                    outcome.fail(path, "dependentRequired", "'\(need)' is a dependency of '\(key)'")
                }
            }
        }
        if case .object(let dependencies)? = schema["dependentSchemas"] {
            for (key, dependent) in dependencies.sorted(by: { $0.key < $1.key }) where object[key] != nil {
                outcome.absorb(evaluate(.object(object), schema: dependent, path: path, base: base))
            }
        }
        var evaluated: Set<String> = []
        if case .object(let properties)? = schema["properties"] {
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                guard let propertySchema = properties[key] else { continue }
                outcome.failures += evaluate(value, schema: propertySchema, path: path + [.key(key)], base: base).failures
                evaluated.insert(key)
            }
        }
        if case .object(let patternProperties)? = schema["patternProperties"] {
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                for (pattern, propertySchema) in patternProperties where patterns.matches(pattern, key) {
                    outcome.failures += evaluate(value, schema: propertySchema, path: path + [.key(key)], base: base).failures
                    evaluated.insert(key)
                }
            }
        }
        if let additional = schema["additionalProperties"] {
            for key in object.keys.sorted() where !evaluated.contains(key) {
                if case .bool(false) = additional {
                    outcome.fail(path, "additionalProperties", "Additional properties are not allowed ('\(key)' was unexpected)", property: key)
                } else {
                    outcome.failures += evaluate(object[key]!, schema: additional, path: path + [.key(key)], base: base).failures
                }
                evaluated.insert(key)
            }
        }
        outcome.evaluated.formUnion(evaluated)
    }

    private func applyCombinators(_ instance: JSONValue, _ schema: JSONValue, _ path: [Failure.PathComponent], _ base: String, _ outcome: inout Outcome) {
        if let all = schema["allOf"]?.arrayValue {
            for branch in all { outcome.absorb(evaluate(instance, schema: branch, path: path, base: base)) }
        }
        if let any = schema["anyOf"]?.arrayValue {
            // Every branch runs: annotations come from each one that passes.
            let results = any.map { evaluate(instance, schema: $0, path: path, base: base) }
            let passing = results.filter(\.isValid)
            if passing.isEmpty {
                outcome.fail(path, "anyOf", "\(Self.short(instance)) is not valid under any of the given schemas", causes: results.flatMap(\.failures))
            } else {
                for result in passing { outcome.evaluated.formUnion(result.evaluated) }
            }
        }
        if let one = schema["oneOf"]?.arrayValue {
            let results = one.map { evaluate(instance, schema: $0, path: path, base: base) }
            let passing = results.filter(\.isValid)
            if passing.count == 1 {
                outcome.evaluated.formUnion(passing[0].evaluated)
            } else if passing.isEmpty {
                outcome.fail(path, "oneOf", "\(Self.short(instance)) is not valid under any of the given schemas", causes: results.flatMap(\.failures))
            } else {
                outcome.fail(path, "oneOf", "\(Self.short(instance)) is valid under each of \(passing.count) of the given schemas")
            }
        }
        if let not = schema["not"], evaluate(instance, schema: not, path: path, base: base).isValid {
            outcome.fail(path, "not", "\(Self.short(instance)) should not be valid under \(Self.short(not))")
        }
        if let condition = schema["if"] {
            let test = evaluate(instance, schema: condition, path: path, base: base)
            if test.isValid {
                outcome.evaluated.formUnion(test.evaluated)
                if let then = schema["then"] { outcome.absorb(evaluate(instance, schema: then, path: path, base: base)) }
            } else if let otherwise = schema["else"] {
                outcome.absorb(evaluate(instance, schema: otherwise, path: path, base: base))
            }
        }
    }

    // MARK: - References

    private func resolve(_ ref: String, base: String) -> (JSONValue, String)? {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let documentPart = String(parts[0])
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        let documentID: String
        if documentPart.isEmpty {
            documentID = base
        } else if documentPart.contains("://") {
            documentID = documentPart
        } else if let baseURL = URL(string: base), let resolved = URL(string: documentPart, relativeTo: baseURL) {
            documentID = resolved.absoluteString
        } else {
            return nil
        }
        guard var node = documents[documentID] else { return nil }
        if !fragment.isEmpty {
            for token in fragment.split(separator: "/").map(Self.unescapePointer) {
                switch node {
                case .object(let object):
                    guard let next = object[token] else { return nil }
                    node = next
                case .array(let array):
                    guard let index = Int(token), array.indices.contains(index) else { return nil }
                    node = array[index]
                default:
                    return nil
                }
            }
        }
        return (node, documentID)
    }

    private static func unescapePointer(_ token: Substring) -> String {
        token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }

    private static func stripFragment(_ id: String) -> String {
        id.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
    }

    private static func collectPatterns(_ node: JSONValue, into found: inout Set<String>) {
        switch node {
        case .object(let object):
            if let pattern = object["pattern"]?.stringValue { found.insert(pattern) }
            if case .object(let patternProperties)? = object["patternProperties"] { found.formUnion(patternProperties.keys) }
            for value in object.values { collectPatterns(value, into: &found) }
        case .array(let array):
            for value in array { collectPatterns(value, into: &found) }
        default:
            break
        }
    }

    // MARK: - Values

    private static func matches(_ instance: JSONValue, type: String) -> Bool {
        switch (type, instance) {
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object), ("null", .null), ("number", .number):
            true
        case ("integer", .number(let value)):
            value.isFinite && value.rounded() == value
        default:
            false
        }
    }

    /// JSON equality: numbers by value, objects regardless of key order.
    static func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        lhs == rhs
    }

    private static func matchesFormat(_ format: String, _ text: String) -> Bool {
        switch format {
        case "date":
            return parseDate(text) != nil
        case "date-time":
            guard let tIndex = text.firstIndex(where: { $0 == "T" || $0 == "t" }) else { return false }
            guard parseDate(String(text[..<tIndex])) != nil else { return false }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if formatter.date(from: text) != nil { return true }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text) != nil
        case "email":
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !text.contains(where: \.isWhitespace)
        default:
            return true // unknown formats are annotations
        }
    }

    /// A real calendar date in `YYYY-MM-DD`.
    public static func parseDate(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard day <= days else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    private static func clip(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(77)) + "…" : text
    }

    private static func short(_ value: JSONValue) -> String {
        let text: String
        switch value {
        case .string(let string): text = "'\(string)'"
        case .number(let number): text = format(number)
        case .bool(let bool): text = bool ? "True" : "False"
        case .null: text = "None"
        case .array, .object:
            text = (try? String(decoding: JSONEncoder.sortedCompact.encode(value), as: UTF8.self)) ?? "…"
        }
        return text.count > 120 ? String(text.prefix(117)) + "…" : text
    }

    private static func list(_ values: [JSONValue]) -> String {
        "[" + values.map(short).joined(separator: ", ") + "]"
    }
}

/// Patterns compiled once (ECMA-262 patterns read as ICU, which agrees for the ones the schemas use).
private final class RegexCache: @unchecked Sendable {
    // Immutable after init, so reads from any thread are safe.
    private let compiled: [String: NSRegularExpression]

    init(patterns: Set<String>) {
        var compiled: [String: NSRegularExpression] = [:]
        for pattern in patterns {
            compiled[pattern] = try? NSRegularExpression(pattern: pattern)
        }
        self.compiled = compiled
    }

    func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = compiled[pattern] ?? (try? NSRegularExpression(pattern: pattern)) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension JSONValue {
    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    /// A whole number (JSON has one number type).
    public var intValue: Int? {
        if case .number(let number) = self, number.rounded() == number, abs(number) < 1e15 { Int(number) } else { nil }
    }
}
