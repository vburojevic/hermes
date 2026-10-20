import Foundation

/// A memory write Hermes staged for review (Ask Before Saving on, and nobody could answer: a
/// task, a background review, a headless chat). Saving applies it exactly as staged; discarding
/// drops it.
public struct MemoryPending: Identifiable, Sendable, Hashable {
    public enum Action: String, Sendable {
        case add, update, remove
    }

    public var id: String
    public var action: Action
    /// `nil` when the record doesn't say (a hand-made record).
    public var store: MemoryStoreKind?
    /// What would be kept, or (for a removal) the entry that would go.
    public var text: String
    /// The whole entry a replace or removal applies to.
    public var matchedEntry: String?
    /// Staged by Hermes's background review rather than a chat nobody could answer.
    public var isBackground: Bool

    public init(id: String, action: Action, store: MemoryStoreKind?, text: String, matchedEntry: String? = nil, isBackground: Bool = false) {
        self.id = id
        self.action = action
        self.store = store
        self.text = text
        self.matchedEntry = matchedEntry
        self.isBackground = isBackground
    }
}

/// Reads `/memory pending`'s reply (`command.dispatch {name: "memory", arg: "pending"}`). The
/// gateway only has this formatted text (`hermes_cli/write_approval_commands.py`), so the parsing
/// lives here and nowhere else, and it gives up quietly on lines it doesn't know:
///
///     Pending memory writes (2):
///       a1b2c3d4  add to user profile: Vegetarian; avoids flights after 21:00.
///       e5f6a7b8 [auto]  background review consolidation (patch on memory): - patch span 'beta 2' -> 'beta 3' (rest of the entry is kept)
///           patchs entry: Studio Mac builds with Xcode 27 beta 2; use xcodebuild -scheme Hermes.
///
///     Apply: /memory approve <id>   Reject: /memory reject <id>
public enum MemoryPendingParser {
    public static func parse(_ text: String) -> [MemoryPending] {
        var records: [(id: String, background: Bool, summary: [String], matched: [String])] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("Apply:") || trimmed.hasPrefix("Pending ") || trimmed.hasPrefix("No pending")
                || trimmed.hasPrefix("memory.write_approval") || trimmed.hasPrefix("Review full diff") {
                continue
            }
            if let head = recordHead(line) {
                records.append((head.id, head.background, [head.summary], []))
                continue
            }
            guard !records.isEmpty else { continue }
            if let matched = matchedEntry(line) {
                records[records.count - 1].matched.append(matched)
            } else {
                // A summary that ran over a line ("…\nwhole entry becomes: …").
                records[records.count - 1].summary.append(trimmed)
            }
        }
        return records.map { record in
            interpret(id: record.id, background: record.background, summary: record.summary.joined(separator: "\n"), matched: record.matched)
        }
    }

    // MARK: Lines

    /// `  <id>[ [auto]]  <summary>`: two spaces, a hex id, the background tag, two spaces.
    static func recordHead(_ line: String) -> (id: String, background: Bool, summary: String)? {
        guard line.hasPrefix("  "), !line.hasPrefix("      ") else { return nil }
        let body = line.dropFirst(2)
        let id = body.prefix { $0.isHexDigit }
        guard id.count >= 6, id.count <= 32 else { return nil }
        var rest = body.dropFirst(id.count)
        var background = false
        if rest.hasPrefix(" [auto]") {
            background = true
            rest = rest.dropFirst(" [auto]".count)
        }
        guard rest.hasPrefix("  ") || rest.isEmpty else { return nil }
        return (String(id), background, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `      <action>s entry: <the whole entry>` under a replace or removal.
    static func matchedEntry(_ line: String) -> String? {
        guard line.hasPrefix("      ") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "s entry: "), trimmed[..<range.lowerBound].allSatisfy(\.isLetter) else { return nil }
        return String(trimmed[range.upperBound...])
    }

    // MARK: Summaries

    static func interpret(id: String, background: Bool, summary: String, matched: [String]) -> MemoryPending {
        let entry = matched.first
        // "add to user profile: <content>", "patch in memory: …", "remove from memory: …",
        // "apply 2 op(s) to memory: …", "background review consolidation (patch on user): …"
        for (prefix, action) in [("add to ", MemoryPending.Action.add), ("replace in ", .update), ("patch in ", .update), ("remove from ", .remove)] {
            guard summary.hasPrefix(prefix), let colon = summary.range(of: ": ") else { continue }
            let label = String(summary[summary.index(summary.startIndex, offsetBy: prefix.count)..<colon.lowerBound])
            let detail = String(summary[colon.upperBound...])
            return MemoryPending(id: id, action: action, store: MemoryStoreKind(target: label),
                                 text: text(for: action, detail: detail, entry: entry), matchedEntry: entry, isBackground: background)
        }
        if summary.hasPrefix("apply "), let to = summary.range(of: " to "), let colon = summary.range(of: ": ", range: to.upperBound..<summary.endIndex) {
            let label = String(summary[to.upperBound..<colon.lowerBound])
            let detail = String(summary[colon.upperBound...])
            return batch(id: id, store: MemoryStoreKind(target: label), detail: detail, entry: entry, background: background)
        }
        if summary.hasPrefix("background review consolidation ("), let close = summary.range(of: "):") {
            let inside = summary[summary.index(summary.startIndex, offsetBy: "background review consolidation (".count)..<close.lowerBound]
            let parts = inside.components(separatedBy: " on ")
            let store = parts.count > 1 ? MemoryStoreKind(target: parts[1]) : nil
            let detail = summary[close.upperBound...].trimmingCharacters(in: .whitespaces)
            return batch(id: id, store: store, detail: detail, entry: entry, background: true)
        }
        return MemoryPending(id: id, action: entry == nil ? .add : .update, store: nil, text: entry ?? summary, matchedEntry: entry, isBackground: background)
    }

    /// The words a row shows for one staged op.
    static func text(for action: MemoryPending.Action, detail: String, entry: String?) -> String {
        switch action {
        case .add:
            return detail.trimmingCharacters(in: .whitespacesAndNewlines)
        case .remove:
            return entry ?? detail.trimmingCharacters(in: .whitespacesAndNewlines)
        case .update:
            // replace: "entry matching: X\nwhole entry becomes: Y"
            if let range = detail.range(of: "whole entry becomes: ") {
                return String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // patch: "entry matching: X\nspan 'X' becomes: Y (rest of the entry is kept)"
            // The arrow is looked for after the span opens: the old text is the agent's own and can
            // carry "' becomes: ", and a range from two separate searches can run backwards (F33).
            if let open = detail.range(of: "span '"), let range = detail.range(of: "' becomes: ", range: open.upperBound..<detail.endIndex) {
                let old = String(detail[open.upperBound..<range.lowerBound])
                var new = String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if new.hasSuffix(" (rest of the entry is kept)") { new = String(new.dropLast(" (rest of the entry is kept)".count)) }
                if let entry, let span = entry.range(of: old) { return entry.replacingCharacters(in: span, with: new) }
                return new
            }
            return detail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A batch ("- add: …", "- remove: …", "- patch span 'a' -> 'b' (…)"): its first op speaks for it.
    static func batch(id: String, store: MemoryStoreKind?, detail: String, entry: String?, background: Bool) -> MemoryPending {
        let ops = detail.components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
        let removes = ops.contains { $0.hasPrefix("remove") }
        let patches = ops.contains { $0.hasPrefix("patch") || $0.hasPrefix("replace") }
        let action: MemoryPending.Action = removes && !patches && entry != nil ? .remove : (patches || removes ? .update : .add)
        var text = entry ?? ""
        if let patch = ops.first(where: { $0.hasPrefix("patch span '") }),
           case let start = patch.index(patch.startIndex, offsetBy: "patch span '".count),
           let arrow = patch.range(of: "' -> '", range: start..<patch.endIndex) {
            let old = String(patch[start..<arrow.lowerBound])
            var new = String(patch[arrow.upperBound...])
            if let end = new.range(of: "' (rest of the entry is kept)") { new = String(new[..<end.lowerBound]) } else if new.hasSuffix("'") { new.removeLast() }
            if let entry, let span = entry.range(of: old) { text = entry.replacingCharacters(in: span, with: new) } else { text = new }
        } else if text.isEmpty, let first = ops.first, let colon = first.range(of: ": ") {
            text = String(first[colon.upperBound...])
        }
        return MemoryPending(id: id, action: action, store: store, text: text.isEmpty ? detail : text, matchedEntry: entry, isBackground: background)
    }

    // MARK: Replies

    /// What `/memory approve <id>` said, for a toast: the entry a replace overwrote, or why it failed.
    public struct ApproveReply: Sendable, Hashable {
        public var applied: Int
        /// The whole entries a save replaced or removed ("re-add anything you still need").
        public var overwritten: [String]
        public var failure: String?
    }

    public static func approveReply(_ text: String) -> ApproveReply {
        var applied = 0
        var overwritten: [String] = []
        var failures: [String] = []
        var section = ""
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Approved "), let count = Int(trimmed.dropFirst("Approved ".count).prefix { $0.isNumber }) {
                applied = count
            } else if trimmed.hasPrefix("Overwrote") || trimmed.hasPrefix("Patched") || trimmed.hasPrefix("Removed") {
                section = "changed"
            } else if trimmed.hasPrefix("Failed:") {
                section = "failed"
            } else if trimmed.hasPrefix("No pending") {
                failures.append(trimmed)
            } else if !trimmed.isEmpty, line.hasPrefix("  ") {
                // "  <id>: <text>"
                let value = trimmed.range(of: ": ").map { String(trimmed[$0.upperBound...]) } ?? trimmed
                if section == "changed" { overwritten.append(value) } else if section == "failed" { failures.append(value) }
            }
        }
        return ApproveReply(applied: applied, overwritten: overwritten, failure: failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }
}
