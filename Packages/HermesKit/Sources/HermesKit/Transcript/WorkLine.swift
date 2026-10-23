import Foundation

/// What a finished turn that used tools and wrote no reply did, in one line from its steps: "Ran
/// the tests and a command · no reply" (`docs/chat.md` §1, 2). A bare "Worked for 6s · 2 tools"
/// read as if a reply were missing. The line never stands in for a reply: it says there was none.
public enum WorkLine {
    /// How many kinds of work the line names before "and N more".
    static let namedKinds = 2

    /// The line for `turn`, or nil when it isn't such a turn: one still running, one with a reply,
    /// with words it said along the way, or with no tools. A Bot that answered with a silence
    /// marker (`keptQuiet`) chose not to reply: the line says none was needed.
    public static func text(for turn: AssistantTurn) -> String? {
        guard turn.state == .complete, turn.answer.isEmpty, turn.audio.isEmpty else { return nil }
        let said = turn.steps.contains { if case .narration(_, let text) = $0 { !text.isEmpty } else { false } }
        guard !said else { return nil }
        let phrases = self.phrases(turn.steps)
        guard !phrases.isEmpty else { return nil }
        let ending = turn.keptQuiet ? String(localized: "no reply needed") : String(localized: "no reply")
        return "\(sentence(phrases)) · \(ending)"
    }

    /// One phrase per kind of work, in the order the turn first did each: "ran 2 commands".
    static func phrases(_ steps: [AssistantStep]) -> [String] {
        var order: [(kind: String, tool: String)] = []
        var counts: [String: Int] = [:]
        for step in steps {
            let kind: String, tool: String
            switch step {
            case .tool(let call): (kind, tool) = (self.kind(of: call), call.name)
            case .subagent: (kind, tool) = ("helpers", "delegate_task")
            case .reasoning, .narration: continue
            }
            if counts[kind] == nil { order.append((kind, tool)) }
            counts[kind, default: 0] += 1
        }
        return order.map { phrase(kind: $0.kind, tool: $0.tool, count: counts[$0.kind] ?? 1) }
    }

    /// Commands are named by what they ran when it's plain ("Tests"), else by their tool.
    static func kind(of tool: ToolActivity) -> String {
        if tool.name == "terminal", let command = tool.startedCommand {
            switch ProcessNaming.name(for: command) {
            case String(localized: "Tests"): return "tests"
            case String(localized: "Build"), String(localized: "Release build"): return "build"
            default: break
            }
        }
        if tool.name == "message_agent" { return "message" }
        return ToolDescriptor.describe(tool.name).symbol
    }

    /// - Parameter tool: the first call of this kind, which names it.
    static func phrase(kind: String, tool: String, count: Int) -> String {
        switch kind {
        case "tests": return String(localized: "ran the tests")
        case "build": return count == 1 ? String(localized: "ran a build") : String(localized: "ran \(count) builds")
        case "message": return count == 1 ? String(localized: "messaged a Bot") : String(localized: "sent \(count) messages to Bots")
        case "helpers": return String(localized: "worked with helpers")
        default:
            let descriptor = ToolDescriptor.describe(tool)
            let title = count == 1 ? descriptor.doneTitle : ToolDescriptor.doneTitle(symbol: kind, count: count) ?? descriptor.doneTitle
            return lowercasedFirst(title)
        }
    }

    /// "Ran the tests and read a file", "Ran 2 commands, read a file and 1 more". A verb the
    /// phrase before used isn't said twice: "Ran the tests and a command".
    static func sentence(_ phrases: [String]) -> String {
        var named = Array(phrases.prefix(namedKinds))
        for index in named.indices.dropFirst() {
            let verb = named[index - 1].prefix { $0 != " " }
            if named[index].hasPrefix(verb + " ") { named[index] = String(named[index].dropFirst(verb.count + 1)) }
        }
        let rest = phrases.count - named.count
        var line: String
        if rest > 0 {
            line = named.joined(separator: ", ") + " " + String(localized: "and \(rest) more")
        } else if named.count == 2 {
            line = String(localized: "\(named[0]) and \(named[1])")
        } else {
            line = named[0]
        }
        line = line.prefix(1).uppercased() + line.dropFirst()
        return line
    }

    static func lowercasedFirst(_ text: String) -> String {
        // "Searched X" keeps its capital: only the verb is lowered.
        text.prefix(1).lowercased() + text.dropFirst()
    }
}

extension ToolDescriptor {
    /// A run of `count` calls of one kind, by its symbol, where English has a plural for it: "Ran
    /// 6 commands", "Read 4 files". Nil for a kind without one.
    public static func doneTitle(symbol: String, count: Int) -> String? {
        switch symbol {
        case "terminal": String(localized: "Ran \(count) commands")
        case "doc.text": String(localized: "Read \(count) files")
        case "pencil.line": String(localized: "Edited \(count) files")
        case "square.and.pencil": String(localized: "Wrote \(count) files")
        case "globe": String(localized: "Searched the web \(count) times")
        case "doc.richtext": String(localized: "Read \(count) pages")
        case "doc.text.magnifyingglass": String(localized: "Searched files \(count) times")
        default: nil
        }
    }
}
