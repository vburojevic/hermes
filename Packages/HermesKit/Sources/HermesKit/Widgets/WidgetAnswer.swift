import CryptoKit
import Foundation
import HermesPush

/// The message a tap sends (`docs/widgets.md` §5, contract §6.2). The client builds every word of
/// it; a payload can't choose them.
///
/// ```
/// [widget w_flights21 rev 1] answer: UA 1187 · 10:55 AM → 2:20 PM
/// {"mid":"9a21d4e8-…","values":{"selected":["ua1187"]},"device":"iPhone"}
/// ```
///
/// Line 1 is for reading (the transcript, the agent), with free text defused. Line 2 is compact
/// JSON and the authoritative part.
public struct WidgetAnswer: Hashable, Sendable {
    public var widgetID: String
    public var rev: Int
    public var action: String
    /// The values in words, from the labels the person saw.
    public var words: String?
    /// A client message id; Try Again sends the same one, so the agent's `claim` answers it once.
    public var mid: String
    public var values: JSONValue
    /// The action's opaque `payload`, echoed back (≤ 1 KB).
    public var echo: JSONValue?
    /// A signed answer's signature (base64 DER), contract §6.3.
    public var sig: String?
    /// The platform word ("iPhone", "iPad", "Mac"), so other devices can say where it was answered.
    public var device: String?

    public init(widgetID: String, rev: Int, action: String, words: String? = nil, mid: String = UUID().uuidString.lowercased(),
                values: JSONValue = .object([:]), echo: JSONValue? = nil, sig: String? = nil, device: String? = nil) {
        self.widgetID = widgetID
        self.rev = rev
        self.action = action
        self.words = words
        self.mid = mid
        self.values = values
        self.echo = echo
        self.sig = sig
        self.device = device
    }

    /// Line 1, as the transcript and the agent read it.
    public var heading: String {
        "[widget \(widgetID) rev \(rev)] \(action)" + (words.map { ": \($0)" } ?? "")
    }

    /// The whole message: line 1, then line 2.
    public var message: String {
        heading + "\n" + Self.compact(details)
    }

    private var details: JSONValue {
        var object: [(String, JSONValue)] = [("mid", .string(mid)), ("values", values)]
        if let echo { object.append(("payload", echo)) }
        if let sig { object.append(("sig", .string(sig))) }
        if let device { object.append(("device", .string(device))) }
        return .object(Dictionary(object, uniquingKeysWith: { first, _ in first }))
    }

    /// A built-in answer as a past action, in a whole phrase ("Approved"); `nil` for a payload's
    /// own action, whose button label says it.
    public static func pastTense(_ action: String) -> String? {
        switch action {
        case "approve": String(localized: "Approved")
        case "reject": String(localized: "Rejected")
        case "edit": String(localized: "Asked for changes")
        case "answer": String(localized: "Answered")
        case "submit": String(localized: "Sent")
        case "cancel": String(localized: "Cancelled")
        case "check": String(localized: "Ticked")
        case "set": String(localized: "Changed")
        case "undo": String(localized: "Undo")
        case "rate": String(localized: "Rated")
        case "acknowledge": String(localized: "Acknowledged")
        case "refresh": String(localized: "Asked for the latest")
        case "retry": String(localized: "Tried again")
        default: nil
        }
    }

    // MARK: - Reading a message

    /// The answer a message carries: line 1 must be the action line. Line 2, when it's there, is
    /// read for the mid and values; a second `[widget …]` line is ignored (one message is one action).
    public static func parse(_ text: String) -> WidgetAnswer? {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard let first = lines.first, let head = parseHeading(first) else { return nil }
        var answer = WidgetAnswer(widgetID: head.id, rev: head.rev, action: head.action, words: head.words, mid: "")
        if lines.count > 1, let details = JSONValue.parse(String(lines[1])), case .object(let object) = details {
            answer.mid = object["mid"]?.stringValue ?? ""
            answer.values = object["values"] ?? .object([:])
            answer.echo = object["payload"]
            answer.sig = object["sig"]?.stringValue
            answer.device = object["device"]?.stringValue
        }
        return answer
    }

    /// `[widget <id> rev <n>] <action>[: <words>]`.
    static func parseHeading(_ line: Substring) -> (id: String, rev: Int, action: String, words: String?)? {
        guard line.hasPrefix("[widget ") else { return nil }
        let rest = line.dropFirst("[widget ".count)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        let id = String(rest[..<space])
        guard WidgetDirective.isWidgetID(id) else { return nil }
        let afterID = rest[rest.index(after: space)...]
        guard afterID.hasPrefix("rev "), let close = afterID.firstIndex(of: "]") else { return nil }
        guard let rev = Int(afterID.dropFirst(4)[..<close]), rev >= 1 else { return nil }
        let tail = afterID[afterID.index(after: close)...]
        guard tail.hasPrefix(" ") else { return nil }
        let body = tail.dropFirst()
        let actionEnd = body.firstIndex(of: ":") ?? body.endIndex
        let action = String(body[..<actionEnd])
        guard !action.isEmpty, action.allSatisfy({ $0.isLowercase || $0.isNumber || "_.-".contains($0) }), action.first!.isLetter else { return nil }
        var words: String?
        if actionEnd < body.endIndex {
            let after = body[body.index(after: actionEnd)...]
            words = after.hasPrefix(" ") ? String(after.dropFirst()) : String(after)
        }
        return (id, rev, action, words)
    }

    // MARK: - Free text on line 1

    /// Line 1 can't be steered by what the person typed (or pasted): free text is put on one line,
    /// quoted, cut at 200 characters and escaped where it starts with `[widget`. The full value
    /// is only in line 2.
    public static func defuse(_ text: String) -> String {
        let oneLine = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0A, 0x0D, 0x09, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: " "
            default: scalar
            }
        }))
        // Invisible and reordering characters show as their codes, as approval text does.
        var line = VisibleText.of(oneLine).trimmingCharacters(in: .whitespaces)
        if line.count > 200 { line = String(line.prefix(200)) + "…" }
        if line.hasPrefix("[widget") { line = "\\" + line }
        return "\"" + line.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Signing (contract §6.3)

    /// `values` as the plugin hashes them: sorted keys, no whitespace, raw UTF-8, slashes
    /// unescaped (Python's `json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`).
    public static func canonical(_ values: JSONValue) -> String {
        compact(values)
    }

    /// What the device key signs: `hermes-widgets-v1|<id>|<rev>|<action>|<sha256 of values>|<mid>`.
    public var signingInput: String {
        let digest = SHA256.hash(data: Data(Self.canonical(values).utf8)).map { String(format: "%02x", $0) }.joined()
        return "hermes-widgets-v1|\(widgetID)|\(rev)|\(action)|\(digest)|\(mid)"
    }

    static func compact(_ value: JSONValue) -> String {
        (try? String(decoding: JSONEncoder.sortedCompact.encode(value), as: UTF8.self)) ?? "{}"
    }
}
