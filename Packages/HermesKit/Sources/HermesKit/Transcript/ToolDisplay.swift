import Foundation

/// What a tool call shows besides its title: a diff, a command's output, search results.
/// Derived from live events when the gateway sends them, else from the stored call and result,
/// so history looks like the live turn did.
extension ToolActivity {
    // MARK: Diffs

    /// The file the call changed.
    public var filePath: String? {
        arguments?["path"]?.stringValue ?? arguments?["file_path"]?.stringValue
    }

    /// The change as a unified diff: `inline_diff` when sent, else built from `patch`'s old and
    /// new strings or the content `write_file` wrote.
    public var displayDiff: String? {
        if let diff, !diff.isEmpty { return diff }
        switch name {
        case "patch":
            guard let old = arguments?["old_string"]?.stringValue, let new = arguments?["new_string"]?.stringValue else { return nil }
            let path = filePath ?? "file"
            // Rows ask on every redraw; the line diff is computed once per edit.
            return ToolDisplayCache.value(for: "patch\u{0}\(path)\u{0}\(old)\u{0}\(new)") {
                let lines = Self.lineDiff(old.components(separatedBy: "\n"), new.components(separatedBy: "\n"))
                return (["--- a/\(path)", "+++ b/\(path)"] + lines).joined(separator: "\n")
            }
        case "write_file":
            guard let content = arguments?["content"]?.stringValue else { return nil }
            return Self.creationDiff(path: filePath ?? "file", content: content)
        default:
            return nil
        }
    }

    /// `old` to `new` as diff lines: lines both keep stay as context, the rest are − or +.
    static func lineDiff(_ old: [String], _ new: [String]) -> [String] {
        let difference = new.difference(from: old)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [String] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append("-" + old[i])
                i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append("+" + new[j])
                j += 1
            } else if j < new.count {
                lines.append(" " + new[j])
                i += 1
                j += 1
            } else {
                i += 1
            }
        }
        return lines
    }

    /// A whole-file write of a file this turn wrote before: what changed since, as hunks with three
    /// lines around each change (the whole file again read as a second, identical "+160 −0" card).
    static func rewriteDiff(path: String, from previous: String, to content: String) -> String {
        ToolDisplayCache.value(for: "rewrite\u{0}\(path)\u{0}\(previous)\u{0}\(content)") {
            let lines = lineDiff(previous.components(separatedBy: "\n"), content.components(separatedBy: "\n"))
            return (["--- a/\(path)", "+++ b/\(path)"] + hunks(lines)).joined(separator: "\n")
        }
    }

    /// The changed lines of a `lineDiff`, with `context` unchanged lines around each run.
    static func hunks(_ lines: [String], context: Int = 3) -> [String] {
        let changed = lines.indices.filter { lines[$0].hasPrefix("+") || lines[$0].hasPrefix("-") }
        var kept = Set<Int>()
        for index in changed {
            kept.formUnion(max(0, index - context)...min(lines.count - 1, index + context))
        }
        var result: [String] = []
        var previous = -2
        for index in kept.sorted() {
            if index != previous + 1 { result.append("@@") }
            result.append(lines[index])
            previous = index
        }
        return result
    }

    /// `content` as a new file.
    static func creationDiff(path: String, content: String) -> String {
        ToolDisplayCache.value(for: "write\u{0}\(path)\u{0}\(content)") {
            let added = content.components(separatedBy: "\n").map { "+" + $0 }
            return (["--- /dev/null", "+++ b/\(path)"] + added).joined(separator: "\n")
        }
    }

    /// Something a folded turn keeps in view: a risk note. Its changes are one row for the turn
    /// (`TurnChanges`, `docs/chat.md` §1).
    public var keepsAttachmentFolded: Bool {
        status != .running && risk != nil
    }

    // MARK: Command output

    /// A command's output and exit code: `result_text` when sent, else the stored result
    /// (`{"output", "exit_code"}` for `terminal`).
    public var commandOutput: CommandOutput? {
        guard ["terminal", "execute_code", "read_terminal", "process_manage"].contains(name) else { return nil }
        var text = output
        var exitCode: Int?
        if let result, let json = ToolDisplayCache.json(result) {
            exitCode = json["exit_code"]?.truncatedIntValue ?? json["returncode"]?.truncatedIntValue
            if text == nil {
                text = json["output"]?.stringValue ?? json["stdout"]?.stringValue
                if let stderr = json["stderr"]?.stringValue, !stderr.isEmpty {
                    text = [text, stderr].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
        } else if text == nil {
            text = result
        }
        // Output of only blanks is none: it drew an output block with nothing in it.
        guard let text = text?.trimmingCharacters(in: .newlines), !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return CommandOutput(text: text, exitCode: exitCode)
    }

    // MARK: Details

    /// The command or arguments the step's details show in full, when they have something to read.
    public var detailsPreview: String? {
        guard let preview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return preview
    }

    /// Whether the step's row opens to anything: the full command, output, a diff, results. A row
    /// that opens always shows something (`ToolDetails`), never an empty box.
    public var hasDetails: Bool {
        guard status != .running else { return false }
        if displayDiff != nil || !searchResults.isEmpty || commandOutput != nil || detailsPreview != nil { return true }
        // Typing into a page and Passwords never show their result (`docs/web.md` §4.1).
        return !WebStep.hidesArguments(name) && result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // MARK: Search results

    /// Results of a web search, numbered so the reply can cite them.
    public var searchResults: [SearchResult] {
        guard name == "web_search" || name == "search_web" || name == "web.search", let result else { return [] }
        if let json = JSONValue.parse(result) {
            let rows: JSONValue? = json["results"] ?? json["data"]?["web"] ?? json["data"] ?? json["web"]
            if case .array(let items)? = rows {
                return items.compactMap { item in
                    guard let title = item["title"]?.stringValue, !title.isEmpty else { return nil }
                    return SearchResult(title: title, url: item["url"]?.stringValue ?? item["link"]?.stringValue)
                }
            }
        }
        // "1. Title — domain" lines.
        return result.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(of: "."), Int(trimmed[..<dot]) != nil else { return nil }
            let rest = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            let parts = rest.components(separatedBy: " — ")
            let title = parts[0]
            let site = parts.count > 1 ? parts[1] : nil
            return title.isEmpty ? nil : SearchResult(title: title, url: site.map { "https://\($0)" })
        }
    }
}

public struct CommandOutput: Hashable, Sendable {
    public var text: String {
        didSet { lines = text.components(separatedBy: "\n") }
    }
    public var exitCode: Int?
    /// Split once: a card asks for them several times per draw.
    public private(set) var lines: [String]

    public init(text: String, exitCode: Int? = nil) {
        self.text = text
        self.exitCode = exitCode
        lines = text.components(separatedBy: "\n")
    }

    public var failed: Bool { (exitCode ?? 0) != 0 }
}

/// Derived tool displays (a patch's line diff, a result's parsed JSON), kept so a row that redraws
/// doesn't redo them. NSCache is thread-safe and empties itself under memory pressure.
enum ToolDisplayCache {
    private final class Box {
        let value: Any?
        init(_ value: Any?) { self.value = value }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        return cache
    }()

    static func value(for key: String, make: () -> String) -> String {
        if let hit = cache.object(forKey: key as NSString)?.value as? String { return hit }
        let value = make()
        cache.setObject(Box(value), forKey: key as NSString)
        return value
    }

    static func json(_ text: String) -> JSONValue? {
        let key = "json\u{0}\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value as? JSONValue }
        let value = JSONValue.parse(text)
        cache.setObject(Box(value), forKey: key)
        return value
    }
}

public struct SearchResult: Hashable, Sendable, Identifiable {
    public var title: String
    public var url: String?

    public var id: String { (url ?? "") + title }

    /// `swift.org` from `https://www.swift.org/blog/…`.
    public var site: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}



extension AssistantTurn {
    /// A whole-file `write_file` after an earlier write of the same file in this turn shows what it
    /// changed since then, the way a live turn's `inline_diff` does, not the whole file again. A
    /// call that came with a diff keeps it; a failed write changed nothing.
    mutating func relateRewrites() {
        var written: [String: String] = [:]
        for index in steps.indices {
            guard case .tool(var tool) = steps[index], tool.name == "write_file", tool.status != .failed,
                  let path = tool.filePath, let content = tool.arguments?["content"]?.stringValue else { continue }
            if let previous = written[path], tool.diff?.isEmpty != false {
                tool.diff = ToolActivity.rewriteDiff(path: path, from: previous, to: content)
                steps[index] = .tool(tool)
            }
            written[path] = content
        }
    }

    /// What a folded turn keeps in view: its risk notes.
    public var foldedAttachments: [ToolActivity] {
        steps.compactMap { step -> ToolActivity? in
            if case .tool(let tool) = step, tool.keepsAttachmentFolded { tool } else { nil }
        }
    }

    /// `foldedAttachments` split where the person's steers were read: the notes before the first,
    /// then those after each steer, so a page read after a steer shows its note after it, not
    /// above it as if it was read before. One group more than there are steers.
    public var foldedAttachmentGroups: [[ToolActivity]] {
        var groups = Array(repeating: [ToolActivity](), count: steers.count + 1)
        let bounds = steers.map(\.afterStep)
        for tool in foldedAttachments {
            let step = steps.firstIndex { if case .tool(let other) = $0 { other.id == tool.id } else { false } } ?? 0
            groups[bounds.filter { $0 <= step }.count].append(tool)
        }
        return groups
    }
}


extension AssistantTurn {
    /// What the turn's fold is remembered by: its first call's id, the same while it streams, once
    /// stored, cached or reloaded. A turn without calls has none (its row's identity stands in).
    public var foldKey: String? {
        for step in steps {
            if case .tool(let tool) = step, let callID = tool.callID, !callID.isEmpty { return "turn:\(callID)" }
        }
        return nil
    }
}
