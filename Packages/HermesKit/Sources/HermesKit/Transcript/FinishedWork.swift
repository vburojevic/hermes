import Foundation

/// What a "background process finished" or "helpers finished" notice is about, read from the text
/// Hermes wrote for the model (`tools/process_registry_notifications.py`). Its clients show a
/// title built from the same facts (`display_text`, which only the dashboard route returns); the
/// content carries all of it on every route (`docs/chat.md` §2a).
public enum FinishedWork: Hashable, Sendable {
    case process(FinishedProcess)
    case helper(FinishedHelper)

    /// The processes or helpers a stored notice names, in order. Empty for any other text.
    public static func parse(kind: String, text: String) -> [FinishedWork] {
        switch kind {
        case "process_complete": FinishedProcess.parse(text).map(FinishedWork.process)
        case "async_delegation_complete": FinishedHelper.parse(text).map(FinishedWork.helper)
        default: []
        }
    }
}

/// One background process Hermes told the chat about.
public struct FinishedProcess: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case succeeded
        case failed(exitCode: Int?)
        /// Stopped (killed), by Hermes or someone.
        case stopped
        /// Hermes lost track of it (its backend went away).
        case lost
        case didNotStart
        /// Still running: its output matched a pattern it was watched for.
        case matched(pattern: String)
    }

    /// What came back from a message to another Bot (`message_agent`'s delivery).
    public enum BotAnswer: Hashable, Sendable {
        case replied(String)
        case failed(String)
    }

    /// `proc_…`: the same id the call that started it got back (`ToolActivity.startedProcessID`).
    public var id: String
    public var command: String
    public var outcome: Outcome
    /// The output Hermes passed on (a tail; its cut note dropped).
    public var output: String
    /// The Bot a message went to (its profile), when this process delivered one.
    public var recipient: String?

    public init(id: String, command: String, outcome: Outcome, output: String, recipient: String? = nil) {
        self.id = id
        self.command = command
        self.outcome = outcome
        self.output = output
        self.recipient = recipient
    }

    static let prefix = "[IMPORTANT: Background process "
    /// What Hermes appends on messaging platforms (`INTERNAL_NOTIFICATION_FOOTER`).
    static let footer = "[INTERNAL NOTIFICATION"

    /// Each block of a notice: one process, or a batch Hermes sends as one ("[IMPORTANT: 3
    /// background processes completed. …]" then a block each).
    public static func parse(_ text: String) -> [FinishedProcess] {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let footer = text.range(of: "\n\n" + footer) { text = String(text[..<footer.lowerBound]) }
        return blocks(text).compactMap(block)
    }

    /// Hermes joins a batch's blocks with a blank line; a block starts with the prefix. Splitting
    /// there, as Hermes Desktop does, keeps a blank line inside an output in its block.
    static func blocks(_ text: String) -> [Substring] {
        var starts: [String.Index] = []
        var search = text.startIndex
        while let found = text.range(of: prefix, range: search..<text.endIndex) {
            if found.lowerBound == text.startIndex || text[..<found.lowerBound].hasSuffix("\n\n") { starts.append(found.lowerBound) }
            search = found.upperBound
        }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
            return text[start..<end]
        }
    }

    static func block(_ raw: Substring) -> FinishedProcess? {
        var block = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard block.hasPrefix(prefix) else { return nil }
        if block.hasSuffix("]") { block.removeLast() }
        let head = block.dropFirst(prefix.count)
        let id = String(head.prefix { !$0.isWhitespace })
        let afterID = head.dropFirst(id.count).drop { $0 == " " }
        let firstLine = afterID.prefix { $0 != "\n" }
        let outcome: Outcome
        if firstLine.hasPrefix("matched watch pattern \"") {
            let pattern = firstLine.dropFirst("matched watch pattern \"".count).prefix { $0 != "\"" }
            outcome = .matched(pattern: String(pattern))
        } else {
            let exit = firstLine.range(of: #"\(exit code (-?\d+)"#, options: .regularExpression).flatMap { range in
                Int(firstLine[range].dropFirst("(exit code ".count))
            }
            if firstLine.hasPrefix("completed normally") {
                outcome = .succeeded
            } else if firstLine.hasPrefix("terminated by") {
                outcome = .stopped
            } else if firstLine.hasPrefix("marked lost") {
                outcome = .lost
            } else if firstLine.hasPrefix("failed to start") {
                outcome = .didNotStart
            } else if firstLine.hasPrefix("exited") {
                outcome = exit == 0 ? .succeeded : .failed(exitCode: exit)
            } else {
                return nil
            }
        }
        let body = afterID.dropFirst(firstLine.count)
        var command = ""
        var output = ""
        if let label = body.range(of: "\nCommand: ") {
            let rest = body[label.upperBound...]
            let commandEnd = rest.range(of: "\nOutput:\n") ?? rest.range(of: "\nMatched output:\n")
            command = String(commandEnd.map { rest[..<$0.lowerBound] } ?? rest.prefix { $0 != "\n" })
            if let commandEnd { output = String(rest[commandEnd.upperBound...]) }
        }
        // Hermes says when it cut the output; the note is for the model.
        if output.hasPrefix("...("), let close = output.range(of: ")\n") { output = String(output[close.upperBound...]) }
        if case .matched = outcome, let note = output.range(of: #"\n\(\d+ earlier matches were suppressed by rate limit\)$"#, options: .regularExpression) {
            output.removeSubrange(note)
        }
        command = command.trimmingCharacters(in: .whitespaces)
        // As the Terminal shows it: no colour codes, progress lines at their last state.
        let cleaned = ProcessOutput(cleaning: output).text
        return FinishedProcess(id: id, command: command, outcome: outcome,
                               output: cleaned.trimmingCharacters(in: .whitespacesAndNewlines),
                               recipient: ProcessNaming.messageRecipient(of: command))
    }

    /// For a delivery to another Bot, what it printed: the Bot's reply (its `hermes chat` prints
    /// it, the live runner as JSON `reply`, the relay after "Reply from <Bot>:"), or why it
    /// failed (tools/bot_mode_dm.py).
    public var answer: BotAnswer? {
        guard recipient != nil || command.contains("bot_mode_dm.py") else { return nil }
        let text = output
        if text.hasPrefix("{"), case .object(let json)? = JSONValue.parse(text) {
            if let reply = json["reply"]?.stringValue, !reply.isEmpty { return .replied(reply) }
            if let error = json["error"]?.stringValue, !error.isEmpty { return .failed(ProcessOutput.errorMessage(in: text) ?? error) }
            return nil
        }
        if text.hasPrefix("Reply from "), let colon = text.range(of: ":\n") {
            let reply = text[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return reply.isEmpty || reply == "(empty reply)" ? nil : .replied(reply)
        }
        if text.hasPrefix("Delivery to "), let failed = text.range(of: " failed") {
            // "Delivery to <Bot> failed [reason: <code>]: <why>".
            var rest = text[failed.upperBound...]
            if rest.hasPrefix(" [reason:"), let close = rest.firstIndex(of: "]") { rest = rest[rest.index(after: close)...] }
            let reason = rest.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return .failed(ProcessOutput.plainWords(reason.isEmpty ? String(localized: "It wasn't delivered.") : reason))
        }
        if text.hasPrefix("No reply from ") { return nil }
        guard outcome == .succeeded, !text.isEmpty else { return nil }
        return .replied(text)
    }

    /// The line for it: "Tests passed", "Build failed · exit 1", "Engineer replied", "Docs site was
    /// stopped". `botName` names a profile as the app does.
    public func line(botName: (String) -> String? = { _ in nil }) -> String {
        if let recipient {
            let bot = ProcessNaming.bot(recipient, botName: botName)
            switch answer {
            case .replied?: return String(localized: "\(bot) replied")
            case .failed?: return String(localized: "Your message to \(bot) wasn't delivered")
            case nil: break
            }
            if outcome == .succeeded { return String(localized: "\(bot) got the message") }
        }
        let name = command.isEmpty ? String(localized: "A background process") : ProcessNaming.name(for: command, botName: botName)
        let isTests = name == String(localized: "Tests")
        switch outcome {
        case .succeeded: return isTests ? String(localized: "Tests passed") : String(localized: "\(name) finished")
        case .failed(let code?): return isTests ? String(localized: "Tests failed · exit \(code)") : String(localized: "\(name) failed · exit \(code)")
        case .failed(nil): return isTests ? String(localized: "Tests failed") : String(localized: "\(name) failed")
        case .stopped: return String(localized: "\(name) was stopped")
        case .lost: return String(localized: "Lost track of \(name)")
        case .didNotStart: return String(localized: "\(name) didn't start")
        case .matched(let pattern): return String(localized: "\(name) printed “\(pattern)”")
        }
    }

    public var isFailure: Bool {
        switch outcome {
        case .failed, .lost, .didNotStart: true
        case .succeeded, .stopped, .matched: if case .failed? = answer { true } else { false }
        }
    }
}

/// One helper (a delegated subagent) whose work came back in a later turn
/// (`[ASYNC DELEGATION COMPLETE — …]`, tools/process_registry_notifications.py).
public struct FinishedHelper: Hashable, Sendable {
    /// The task it was given (`goal`).
    public var goal: String
    /// Hermes's status word: `completed`, `failed`, `timeout`, `interrupted`…
    public var status: String
    /// What it found, or why it didn't finish.
    public var result: String

    public init(goal: String, status: String, result: String) {
        self.goal = goal
        self.status = status
        self.result = result
    }

    public var succeeded: Bool { status == "completed" || status == "success" }

    static let single = "[ASYNC DELEGATION COMPLETE"
    static let batch = "[ASYNC DELEGATION BATCH COMPLETE"
    static let earlyFailure = "[ASYNC DELEGATION TASK FAILED"
    static let resultMarker = "--- RESULT ---"

    public static func parse(_ text: String) -> [FinishedHelper] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if text.hasPrefix(batch) {
            // `--- ✓ TASK 1/3: <goal>  (status=completed, api_calls=4, 12s) ---`, then its summary.
            var helpers: [FinishedHelper] = []
            var current: (goal: String, status: String, body: [String])?
            func close() {
                if let current { helpers.append(FinishedHelper(goal: current.goal, status: current.status, result: Self.result(current.body))) }
            }
            for line in lines {
                if let task = taskHeader(line) {
                    close()
                    current = (task.goal, task.status, [])
                } else if current != nil {
                    current?.body.append(line)
                }
            }
            close()
            return helpers
        }
        if text.hasPrefix(single) {
            let goal = value(after: "Original goal: ", in: lines) ?? ""
            let status = value(after: "Status: ", in: lines).map { String($0.prefix { !$0.isWhitespace }) } ?? "completed"
            let body = lines.firstIndex(of: resultMarker).map { Array(lines[($0 + 1)...]) } ?? []
            return [FinishedHelper(goal: goal, status: status, result: result(body))]
        }
        if text.hasPrefix(earlyFailure) {
            let goal = value(after: "Task: ", in: lines) ?? ""
            let status = value(after: "Status: ", in: lines).map { String($0.prefix { !$0.isWhitespace }) } ?? "failed"
            return [FinishedHelper(goal: goal, status: status, result: value(after: "Error: ", in: lines) ?? "")]
        }
        return []
    }

    static func value(after label: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix(label) }.map { String($0.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
    }

    static func taskHeader(_ line: String) -> (goal: String, status: String)? {
        guard line.hasPrefix("--- "), line.hasSuffix(" ---"), line.contains(" TASK "),
              let status = line.range(of: "(status=") else { return nil }
        let statusWord = line[status.upperBound...].prefix { $0 != "," && $0 != ")" }
        var head = line[..<status.lowerBound]
        if let colon = head.range(of: ": ") { head = head[colon.upperBound...] } else { head = "" }
        return (head.trimmingCharacters(in: .whitespaces), String(statusWord))
    }

    /// A task's body without Hermes's notes to the model: its truncation note, transcript paths and
    /// process accounting.
    static func result(_ body: [String]) -> String {
        let kept = body.compactMap { line -> String? in
            if line.hasPrefix("[TRUNCATED") || line.hasPrefix("Full live transcript") || line.hasPrefix("Handed off to you:")
                || line.hasPrefix("Child left ") || line.hasPrefix("Child's process ") || line == "Partial output:" { return nil }
            // `(no summary — status=timeout: <why>)` and `(<status>: <why>)`: the why alone, the
            // status shows already.
            if line.hasPrefix("("), line.hasSuffix(")"),
               line.hasPrefix("(no summary") || line.range(of: #"^\([a-z_]+: "#, options: .regularExpression) != nil {
                guard let colon = line.range(of: ": ") else { return nil }
                let why = line[colon.upperBound...].dropLast().trimmingCharacters(in: .whitespaces)
                return why.isEmpty ? nil : ProcessOutput.plainWords(why) + (why.hasSuffix(".") ? "" : ".")
            }
            return line
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Its name in a line: the goal's first four words.
    public var title: String {
        let words = goal.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return String(localized: "A helper") }
        let short = words.prefix(4).joined(separator: " ")
        return words.count > 4 ? short + "…" : short
    }

    public var outcomeWord: String {
        switch status {
        case "completed", "success": String(localized: "done")
        case "timeout": String(localized: "timed out")
        case "interrupted", "cancelled": String(localized: "stopped")
        default: String(localized: "failed")
        }
    }
}

extension Notice {
    /// The line a notice of finished work reads as, from what it's about: "Tests passed", "3
    /// background processes finished · 1 failed", "2 helpers finished: Research, Review". Nil
    /// when it names nothing (the notice keeps its own words).
    public static func finishedLine(_ work: [FinishedWork], botName: (String) -> String? = { _ in nil }) -> String? {
        let processes = work.compactMap { if case .process(let process) = $0 { process } else { nil } }
        let helpers = work.compactMap { if case .helper(let helper) = $0 { helper } else { nil } }
        if !processes.isEmpty, helpers.isEmpty {
            if processes.count == 1 { return processes[0].line(botName: botName) }
            let failed = processes.filter(\.isFailure).count
            let replies = processes.filter { if case .replied? = $0.answer { true } else { false } }.count
            if replies == processes.count {
                let bots = unique(processes.compactMap(\.recipient).map { ProcessNaming.bot($0, botName: botName) })
                return bots.count == 1 ? String(localized: "\(bots[0]) replied \(processes.count) times") : String(localized: "\(processes.count) replies from Bots")
            }
            let line = String(localized: "\(processes.count) background processes finished")
            return failed > 0 ? String(localized: "\(line) · \(failed) failed") : line
        }
        if !helpers.isEmpty, processes.isEmpty {
            let failed = helpers.filter { !$0.succeeded }.count
            if helpers.count == 1 {
                let helper = helpers[0]
                return helper.succeeded ? String(localized: "Helper finished: \(helper.title)") : String(localized: "Helper \(helper.outcomeWord): \(helper.title)")
            }
            let names = helpers.prefix(3).map(\.title).joined(separator: ", ") + (helpers.count > 3 ? ", …" : "")
            let line = String(localized: "\(helpers.count) helpers finished: \(names)")
            return failed > 0 ? String(localized: "\(line) · \(failed) failed") : line
        }
        return nil
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}

extension TranscriptBuilder {
    /// The turn whose step started process `id` (`terminal` with `background`, `message_agent`),
    /// which a notice of it finishing links back to.
    public static func turn(startingProcess id: String, in items: [TranscriptItem]) -> AssistantTurn? {
        for item in items.reversed() {
            guard case .assistant(let turn) = item else { continue }
            if turn.steps.contains(where: { if case .tool(let tool) = $0 { tool.startedProcessID == id } else { false } }) { return turn }
        }
        return nil
    }

    /// What a notice said about process `id` once it finished: for a message to another Bot, the
    /// reply carried back.
    public static func finished(process id: String, in items: [TranscriptItem]) -> FinishedProcess? {
        for item in items {
            guard case .notice(let notice) = item else { continue }
            for case .process(let process) in notice.work where process.id == id { return process }
        }
        return nil
    }
}
