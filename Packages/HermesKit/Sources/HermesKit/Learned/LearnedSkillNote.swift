import Foundation

// "Learned a new skill: <name>" under a reply (`docs/chat.md`, `docs/learned.md` §6): Hermes
// wrote a skill with `skill_manage` (`action: create`), and the write landed rather than waiting
// for approval.

extension ToolActivity {
    /// The skills this call created.
    public var createdSkills: [String] {
        guard name == "skill_manage", status == .succeeded else { return [] }
        let args = arguments ?? .object([:])
        let resultJSON = (output ?? result).flatMap { text -> JSONValue? in
            guard let data = text.data(using: .utf8) else { return nil }
            return JSONValue.parse(data)
        }
        if resultJSON?["success"]?.boolValue == false || resultJSON?["staged"]?.boolValue == true { return [] }
        let listed = args["operations"].items
        let ops = listed.isEmpty ? [args] : listed
        let fallback = args["name"]?.stringValue
        return ops.compactMap { op in
            guard (op["action"]?.stringValue ?? "").lowercased() == "create" else { return nil }
            let name = (op["name"]?.stringValue ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

extension AssistantTurn {
    /// The skills Hermes wrote in this turn, in order, each once.
    public var createdSkills: [String] {
        var seen = Set<String>()
        return steps.flatMap { step -> [String] in
            if case .tool(let tool) = step { return tool.createdSkills }
            return []
        }.filter { seen.insert($0).inserted }
    }
}
