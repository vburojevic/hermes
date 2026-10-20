import Foundation

/// What the `memory` tool did in a turn (`docs/memory.md` §2): one quiet line after the reply.
public struct MemoryChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// "Remembered: …"
        case saved
        /// "Updated memory: …"
        case updated
        /// "Forgot: …"
        case forgot
        /// Staged for review: "1 memory waiting for your review".
        case waiting
    }

    public var kind: Kind
    public var store: MemoryStoreKind
    /// The entry as it is now (saved, updated), as it was (forgot), or as proposed (waiting).
    public var text: String

    public var id: String { "\(kind)·\(store.rawValue)·\(text)" }

    public init(kind: Kind, store: MemoryStoreKind, text: String) {
        self.kind = kind
        self.store = store
        self.text = text
    }
}

extension ToolActivity {
    /// The memory changes this step made: one per op of a batch; none when it failed or was
    /// refused. A staged write is `.waiting`.
    public var memoryChanges: [MemoryChange] {
        guard name == "memory", status == .succeeded else { return [] }
        let args = arguments ?? .object([:])
        let resultJSON = (output ?? result).flatMap { text -> JSONValue? in
            guard let data = text.data(using: .utf8) else { return nil }
            return JSONValue.parse(data)
        }
        if resultJSON?["success"]?.boolValue == false { return [] }
        let store = MemoryStoreKind(target: args["target"]?.stringValue ?? resultJSON?["target"]?.stringValue ?? "memory") ?? .notes
        let staged = resultJSON?["staged"]?.boolValue == true
        let ops: [JSONValue] = {
            let listed = args["operations"].items
            return listed.isEmpty ? [args] : listed
        }()
        let single = ops.count == 1
        return ops.compactMap { op in
            let action = (op["action"]?.stringValue ?? "add").lowercased()
            let content = (op["content"]?.stringValue ?? op["new_text"]?.stringValue ?? op["text"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let old = op["old_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch action {
            case "add", "save":
                guard let content, !content.isEmpty else { return nil }
                return MemoryChange(kind: staged ? .waiting : .saved, store: store, text: content)
            case "replace", "patch":
                // The whole entry after the edit, when the result carries it.
                let after = single ? resultJSON?["patched_entry_after"]?.stringValue : nil
                let text = after ?? (action == "replace" ? content : nil) ?? content ?? old
                guard let text, !text.isEmpty else { return nil }
                return MemoryChange(kind: staged ? .waiting : .updated, store: store, text: text)
            case "remove":
                let removed = single ? resultJSON?["removed_entry"]?.stringValue : nil
                guard let text = removed ?? old, !text.isEmpty else { return nil }
                return MemoryChange(kind: staged ? .waiting : .forgot, store: store, text: text)
            default:
                return nil
            }
        }
    }

    /// What the memory tool kept ("you prefer 24-hour times").
    public var rememberedText: String? {
        memoryChanges.first { $0.kind == .saved || $0.kind == .updated }?.text
    }
}

extension AssistantTurn {
    /// Every memory change the turn made, in order.
    public var memoryChanges: [MemoryChange] {
        steps.flatMap { step -> [MemoryChange] in
            if case .tool(let tool) = step { return tool.memoryChanges }
            return []
        }
    }
}

extension ApprovalRequest {
    /// The memory tool asking before it saves (Ask Before Saving on): titled "Save to memory?",
    /// never offering Always (`allow_permanent: false`). The request has no kind field; the
    /// title, or the "Save to memory: …" description it comes with, tells it apart. Another
    /// asker brings its own title ("<server> is asking"), so a title decides on its own: a tool
    /// can't pass for a memory save by starting its description the same way.
    public var isMemorySave: Bool {
        guard !smartDenied else { return false }
        if let title { return title == "Save to memory?" }
        return description?.hasPrefix("Save to memory: ") ?? false
    }

    /// A memory save as the gateway itself titles it (current gateways).
    public var isTitledMemorySave: Bool {
        !smartDenied && title == "Save to memory?"
    }

    /// The store the save goes to: "Save to memory: add to user profile" is About You.
    public var memoryStore: MemoryStoreKind {
        let text = (description ?? "").lowercased()
        return text.contains("user profile") ? .about : .notes
    }

    /// What Hermes wants to keep. A replace says "entry matching: …\nwhole entry becomes: …", a
    /// patch "entry matching: …\nspan '…' becomes: … (rest of the entry is kept)"; an add is the
    /// entry as the model wrote it. Only the gateway's own replace and patch layouts are taken
    /// apart, as its description names them, and everything after the first marker shows: a
    /// marker the model wrote into an added entry is just words, so it can't hide the part before
    /// it (security scan F12, F13).
    public var memoryText: String {
        let detail = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (description ?? "").lowercased()
        if detail.hasPrefix("entry matching: ") {
            if action.contains(": replace in "), let range = detail.range(of: "\nwhole entry becomes: ") {
                return String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if action.contains(": patch in "), let range = detail.range(of: "' becomes: ") {
                var text = String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasSuffix("(rest of the entry is kept)") {
                    text = String(text.dropLast("(rest of the entry is kept)".count)).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
        }
        if !detail.isEmpty { return detail }
        let summary = description ?? ""
        return summary.range(of: ": ").map { String(summary[$0.upperBound...]) } ?? summary
    }
}
