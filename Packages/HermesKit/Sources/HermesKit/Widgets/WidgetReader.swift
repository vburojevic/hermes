import Foundation

/// A widget the app shows as text: an unknown type, a newer major version, or a payload that
/// doesn't hold together (`docs/widgets.md` §3). It is never half drawn.
public struct WidgetFallback: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case unknownType(String)
        case newerVersion(Int)
        /// The first thing wrong, for the widget menu ("Shown as text: consequences.cost is required").
        case invalid(String)
    }

    public var id: String?
    public var rev: Int
    public var type: String?
    public var title: String?
    /// `fallback_text`, when the payload carried one.
    public var text: String?
    public var reason: Reason
    /// Read failing closed: anything but `normal` is private.
    public var isPrivate: Bool
    public var json: JSONValue

    public init(id: String?, rev: Int, type: String?, title: String?, text: String?, reason: Reason, isPrivate: Bool, json: JSONValue) {
        self.id = id
        self.rev = rev
        self.type = type
        self.title = title
        self.text = text
        self.reason = reason
        self.isPrivate = isPrivate
        self.json = json
    }
}

/// Reads payloads as the client must (payload contract §10): lenient within a major version,
/// failing closed. Unknown fields are left out; an unknown value draws its safe default (an
/// unknown `sensitivity` is private, an approval of an unknown kind is a transfer, an unknown
/// action kind or link scheme is dropped, an unknown state is `info`, an unknown layout or style
/// is the default). Anything else wrong, a missing required field above all, falls back to text.
public enum WidgetReader {
    public enum Result: Hashable, Sendable {
        case ready(WidgetPayload)
        case fallback(WidgetFallback)

        public var payload: WidgetPayload? {
            if case .ready(let payload) = self { payload } else { nil }
        }

        public var id: String? {
            switch self {
            case .ready(let payload): payload.id
            case .fallback(let fallback): fallback.id
            }
        }

        public var rev: Int {
            switch self {
            case .ready(let payload): payload.rev
            case .fallback(let fallback): fallback.rev
            }
        }

        public var isPrivate: Bool {
            switch self {
            case .ready(let payload): payload.isPrivate || payload.children.contains(where: \.isPrivate)
            case .fallback(let fallback): fallback.isPrivate
            }
        }
    }

    /// The ids the client builds answers with; payload actions can't take them (rule `actions.ids`).
    /// A type's own built-in answers may be envelope actions (an alert's Acknowledge, contract §6.1).
    static let ownBuiltIns: [WidgetType: Set<String>] = [
        .alert: ["acknowledge"], .choice: ["answer"], .form: ["submit", "cancel"], .compare: ["answer"],
    ]

    public static let reservedActionIDs: Set<String> = [
        "answer", "submit", "cancel", "check", "set", "approve", "edit", "reject", "undo", "rate",
        "acknowledge", "refresh", "retry",
    ]

    public static func read(_ json: JSONValue, spec: WidgetSpec = .shared) -> Result {
        guard case .object(let object) = json else {
            return .fallback(fallback(json, reason: .invalid("the payload isn't a JSON object")))
        }
        guard let typeName = object["type"]?.stringValue else {
            return .fallback(fallback(json, reason: .invalid("'type' is a required property")))
        }
        guard let type = WidgetType(rawValue: typeName) else {
            return .fallback(fallback(json, reason: .unknownType(typeName)))
        }
        if let version = object["v"]?.intValue, version > WidgetSpec.knownVersion {
            return .fallback(fallback(json, reason: .newerVersion(version)))
        }
        var (normalized, failures) = lenient(json, type: type, spec: spec)
        if failures.isEmpty, type == .stack {
            // Each child is a widget of its own and holds up on its own (rule `stack.children`).
            var children: [JSONValue] = []
            for (index, child) in (normalized["children"]?.arrayValue ?? []).enumerated() {
                switch read(child, spec: spec) {
                case .ready(let payload):
                    children.append(payload.json)
                case .fallback(let fallback):
                    switch fallback.reason {
                    case .unknownType, .newerVersion:
                        // A type this app can't draw shows as its own text; the others still draw.
                        children.append(child)
                    case .invalid(let why):
                        failures.append("children[\(index)] (\(fallback.type ?? "?")): \(why)")
                    }
                }
            }
            if failures.isEmpty, case .object(var stack) = normalized {
                stack["children"] = .array(children)
                // Any private child makes the stack private.
                if children.contains(where: { $0["sensitivity"] != nil && $0["sensitivity"]?.stringValue != "normal" }) {
                    stack["sensitivity"] = .string("private")
                }
                normalized = .object(stack)
            }
        }
        if failures.isEmpty { failures = clientRuleFailures(normalized, type: type) }
        guard failures.isEmpty else {
            return .fallback(fallback(json, reason: .invalid(failures[0])))
        }
        do {
            return .ready(try WidgetPayload.decode(normalized))
        } catch {
            return .fallback(fallback(json, reason: .invalid("couldn't be read")))
        }
    }

    /// Every reason the producer would refuse the payload: the full schemas, strictly, plus the
    /// semantic rules the app checks. Tests and the gallery use it; the chat uses `read`.
    public static func strictFailures(_ json: JSONValue, spec: WidgetSpec = .shared) -> [String] {
        guard let typeName = json["type"]?.stringValue else { return ["'type' is a required property"] }
        guard let type = WidgetType(rawValue: typeName) else { return ["unknown type \(typeName)"] }
        var failures = spec.validator.validate(json, schemaID: WidgetSpec.schemaID(typeName)).map(\.description)
        if type == .stack {
            for (index, child) in (json["children"]?.arrayValue ?? []).enumerated() {
                failures += strictFailures(child, spec: spec).map { "children[\(index)]: \($0)" }
            }
        }
        return failures + clientRuleFailures(json, type: type)
    }

    // MARK: - Leniency

    private typealias Path = [JSONSchemaValidator.Failure.PathComponent]

    private enum Fix {
        case remove(Path)
        case set(Path, JSONValue)

        var path: Path {
            switch self {
            case .remove(let path), .set(let path, _): path
            }
        }
    }

    /// Applies the fail-closed defaults until the payload validates, or nothing more can be
    /// forgiven. Returns the payload as read and what still fails.
    private static func lenient(_ json: JSONValue, type: WidgetType, spec: WidgetSpec) -> (JSONValue, [String]) {
        var current = json
        let schemaID = WidgetSpec.schemaID(type.rawValue)
        for _ in 0..<24 {
            let failures = spec.validator.validate(current, schemaID: schemaID)
            if failures.isEmpty { return (current, []) }
            var fixes: [Fix] = []
            collectFixes(failures, type: type, into: &fixes)
            // Only a name the schema doesn't know is an unknown field: a known one in the wrong
            // place (a fifth outline level) is over a limit, and the client cuts nothing silently.
            let known = spec.knownProperties[type.rawValue] ?? []
            fixes.removeAll { fix in
                guard case .remove(let path) = fix, case .key(let key)? = path.last else { return false }
                return isUnknownProperty(fix, in: failures) && known.contains(key)
            }
            // A subschema that fails (the envelope, over an unknown sensitivity) drops its
            // annotations, so its fields read as unevaluated until it passes: forgive the rest
            // first, and only then leave out what is really unknown.
            let values = fixes.filter { if case .set = $0 { true } else { !isUnknownProperty($0, in: failures) } }
            if !values.isEmpty { fixes = values }
            // Array elements go last and highest index first, so the other fixes keep their place.
            fixes.sort { lhs, rhs in
                let left = sortKey(lhs.path), right = sortKey(rhs.path)
                return (left.isElement ? 1 : 0, left.parent, -left.index) < (right.isElement ? 1 : 0, right.parent, -right.index)
            }
            var changed = false
            var seen: Set<Path> = []
            for fix in fixes where seen.insert(fix.path).inserted {
                if apply(fix, to: &current) { changed = true }
            }
            if !changed { return (current, failures.map(\.description)) }
        }
        return (current, spec.validator.validate(current, schemaID: schemaID).map(\.description))
    }

    private static func isUnknownProperty(_ fix: Fix, in failures: [JSONSchemaValidator.Failure]) -> Bool {
        guard case .remove(let path) = fix, case .key(let key)? = path.last else { return false }
        let parent = Array(path.dropLast())
        func matches(_ failure: JSONSchemaValidator.Failure) -> Bool {
            (failure.property == key && failure.path == parent) || failure.causes.contains(where: matches)
        }
        return failures.contains(where: matches)
    }

    private static func sortKey(_ path: Path) -> (isElement: Bool, parent: String, index: Int) {
        guard case .index(let index)? = path.last else { return (false, "", 0) }
        return (true, JSONSchemaValidator.Failure.location(Array(path.dropLast())), index)
    }

    private static func collectFixes(_ failures: [JSONSchemaValidator.Failure], type: WidgetType, into fixes: inout [Fix]) {
        for failure in failures {
            if let fix = forgivingFix(failure, type: type) { fixes.append(fix) }
            collectFixes(failure.causes, type: type, into: &fixes)
        }
    }

    /// What the client does instead of falling back, when the contract's table allows it.
    private static func forgivingFix(_ failure: JSONSchemaValidator.Failure, type: WidgetType) -> Fix? {
        let path = failure.path
        switch failure.keyword {
        case "unevaluatedProperties", "additionalProperties":
            return failure.property.map { .remove(path + [.key($0)]) }
        case "enum":
            guard case .key(let key)? = path.last else { return nil }
            let parent: String? = if path.count >= 2, case .key(let name) = path[path.count - 2] { name } else { nil }
            let allowed = Set((failure.allowed ?? []).compactMap(\.stringValue))
            switch key {
            case "sensitivity":
                return .set(path, .string("private"))
            case "state":
                if allowed.contains("info") { return .set(path, .string("info")) }
                if allowed.contains("unknown") { return .set(path, .string("unknown")) }
                return nil
            case "layout", "style", "view":
                return .remove(path)
            case "requires":
                return .set(path, .string("authentication"))
            case "authentication" where type == .approval:
                return .set(path, .string("required"))
            case "reversible" where parent == "consequences":
                return .set(path, .string("no"))
            case "kind" where parent == "subject" && type == .approval:
                return .set(path, .string("transfer"))
            case "kind" where isInsideAction(path):
                return .remove(Array(path.dropLast()))
            default:
                return nil
            }
        case "pattern":
            guard case .key(let key)? = path.last, key == "url" else { return nil }
            // A link with a scheme the app doesn't open is dropped, and an action with it.
            return isInsideAction(path) ? .remove(Array(path.dropLast())) : .remove(path)
        default:
            return nil
        }
    }

    /// `…/actions/<n>/<key>` or `…/do_first/action/<key>`.
    private static func isInsideAction(_ path: Path) -> Bool {
        guard path.count >= 3 else { return false }
        if case .index = path[path.count - 2], case .key("actions") = path[path.count - 3] { return true }
        if case .key("action") = path[path.count - 2] { return true }
        return false
    }

    private static func apply(_ fix: Fix, to value: inout JSONValue) -> Bool {
        switch fix {
        case .remove(let path): return update(&value, path[...]) { _ in nil }
        case .set(let path, let new): return update(&value, path[...]) { _ in new }
        }
    }

    /// Replaces (or with `nil`, removes) the value at `path`. Returns whether anything changed.
    private static func update(_ value: inout JSONValue, _ path: ArraySlice<JSONSchemaValidator.Failure.PathComponent>,
                               _ change: (JSONValue) -> JSONValue?) -> Bool {
        guard let first = path.first else { return false }
        let rest = path.dropFirst()
        switch (first, value) {
        case (.key(let key), .object(var object)):
            guard let child = object[key] else { return false }
            if rest.isEmpty {
                let new = change(child)
                if new == child { return false }
                object[key] = new
            } else {
                var child = child
                guard update(&child, rest, change) else { return false }
                object[key] = child
            }
            value = .object(object)
            return true
        case (.index(let index), .array(var array)):
            guard array.indices.contains(index) else { return false }
            if rest.isEmpty {
                if let new = change(array[index]) {
                    if new == array[index] { return false }
                    array[index] = new
                } else {
                    array.remove(at: index)
                }
            } else {
                guard update(&array[index], rest, change) else { return false }
            }
            value = .array(array)
            return true
        default:
            return false
        }
    }

    // MARK: - Semantic rules the client checks

    /// `actions.ids`, `actions.primary` and `actions.destructive` (semantic-rules.md, "both").
    static func clientRuleFailures(_ json: JSONValue, type: WidgetType) -> [String] {
        var failures: [String] = []
        var groups: [(String, [JSONValue])] = []
        collectActions(json, path: "", into: &groups)
        for (path, actions) in groups {
            var ids: Set<String> = []
            // Widget-level buttons share the message's action slot with the built-in answers; a
            // row's own actions travel with `{item}`, so only these can't take a built-in id.
            let isWidgetLevel = path == "actions" || path == "do_first.action"
            for (index, action) in actions.enumerated() {
                let location = "\(path)[\(index)]"
                if let id = action["id"]?.stringValue {
                    if isWidgetLevel, reservedActionIDs.contains(id), ownBuiltIns[type]?.contains(id) != true { failures.append("\(location).id \"\(id)\" is reserved; use another id") }
                    if !ids.insert(id).inserted { failures.append("\(location).id \"\(id)\" is used twice") }
                }
                let kind = action["kind"]?.stringValue ?? "reply"
                if action["style"]?.stringValue == "destructive", action["confirm"] == nil {
                    failures.append("\(location): destructive needs confirm")
                }
                if kind == "open", action["url"] == nil { failures.append("\(location): open needs url") }
                if kind == "copy", action["value"] == nil { failures.append("\(location): copy needs value") }
            }
        }
        var primaries = (json["actions"]?.arrayValue ?? []).filter { $0["style"]?.stringValue == "primary" }.count
        if type == .summary, json["do_first"]?["action"] != nil { primaries += 1 }
        if primaries > 1 { failures.append("two primary actions; make one secondary") }
        return failures
    }

    private static func collectActions(_ value: JSONValue, path: String, into groups: inout [(String, [JSONValue])]) {
        switch value {
        case .object(let object):
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if path.isEmpty, key == "children", object["type"]?.stringValue == "stack" { continue } // checked as widgets of their own
                if key == "actions", case .array(let actions) = child {
                    groups.append((childPath, actions))
                } else if key == "action", case .object = child {
                    groups.append((childPath, [child]))
                } else {
                    collectActions(child, path: childPath, into: &groups)
                }
            }
        case .array(let array):
            for (index, child) in array.enumerated() {
                collectActions(child, path: "\(path)[\(index)]", into: &groups)
            }
        default:
            break
        }
    }

    // MARK: - Falling back

    private static func fallback(_ json: JSONValue, reason: WidgetFallback.Reason) -> WidgetFallback {
        let sensitivity = json["sensitivity"]
        return WidgetFallback(
            id: json["id"]?.stringValue,
            rev: json["rev"]?.intValue ?? 1,
            type: json["type"]?.stringValue,
            title: json["title"]?.stringValue,
            text: json["fallback_text"]?.stringValue,
            reason: reason,
            isPrivate: sensitivity != nil && sensitivity?.stringValue != "normal",
            json: json
        )
    }
}
