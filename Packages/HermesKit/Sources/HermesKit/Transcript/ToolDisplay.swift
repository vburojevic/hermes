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
            let lines = Self.lineDiff(old.components(separatedBy: "\n"), new.components(separatedBy: "\n"))
            return (["--- a/\(filePath ?? "file")", "+++ b/\(filePath ?? "file")"] + lines).joined(separator: "\n")
        case "write_file":
            guard let content = arguments?["content"]?.stringValue else { return nil }
            let added = content.components(separatedBy: "\n").map { "+" + $0 }
            return (["--- /dev/null", "+++ b/\(filePath ?? "file")"] + added).joined(separator: "\n")
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

    // MARK: Command output

    /// A command's output and exit code: `result_text` when sent, else the stored result
    /// (`{"output", "exit_code"}` for `terminal`).
    public var commandOutput: CommandOutput? {
        guard ["terminal", "execute_code", "read_terminal", "process_manage"].contains(name) else { return nil }
        var text = output
        var exitCode: Int?
        if let result, let json = JSONValue.parse(result) {
            exitCode = json["exit_code"]?.doubleValue.map { Int($0) } ?? json["returncode"]?.doubleValue.map { Int($0) }
            if text == nil {
                text = json["output"]?.stringValue ?? json["stdout"]?.stringValue
                if let stderr = json["stderr"]?.stringValue, !stderr.isEmpty {
                    text = [text, stderr].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
        } else if text == nil {
            text = result
        }
        guard let text = text?.trimmingCharacters(in: .newlines), !text.isEmpty else { return nil }
        return CommandOutput(text: text, exitCode: exitCode)
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
    public var text: String
    public var exitCode: Int?

    public var lines: [String] { text.components(separatedBy: "\n") }
    public var failed: Bool { (exitCode ?? 0) != 0 }
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

extension ToolActivity {
    /// What the memory tool kept ("you prefer 24-hour times"), for `memoryNote`.
    public var rememberedText: String? {
        guard name == "memory" else { return nil }
        let action = arguments?["action"]?.stringValue ?? "add"
        guard action == "add" || action == "replace" || action == "save" else { return nil }
        return (arguments?["content"]?.stringValue ?? arguments?["text"]?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
