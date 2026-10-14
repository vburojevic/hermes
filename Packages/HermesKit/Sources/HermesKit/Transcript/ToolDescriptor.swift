import Foundation

/// How a Hermes tool call reads in the transcript: a verb phrase and an SF Symbol.
public struct ToolDescriptor: Hashable, Sendable {
    /// Present tense while running ("Searching the web").
    public var activeTitle: String
    /// Past tense once done ("Searched the web").
    public var doneTitle: String
    public var symbol: String

    public init(activeTitle: String, doneTitle: String, symbol: String) {
        self.activeTitle = activeTitle
        self.doneTitle = doneTitle
        self.symbol = symbol
    }

    /// The checklist tool (`todo_list`, and its older `todo` name): shown as the plan card.
    public static func isPlanTool(_ name: String) -> Bool {
        name == "todo_list" || name == "todo"
    }

    public static func describe(_ name: String) -> ToolDescriptor {
        switch name {
        case "terminal", "read_terminal", "close_terminal", "process_manage":
            ToolDescriptor(activeTitle: "Running a command", doneTitle: "Ran a command", symbol: "terminal")
        case "execute_code":
            ToolDescriptor(activeTitle: "Running code", doneTitle: "Ran code", symbol: "chevron.left.forwardslash.chevron.right")
        case "read_file":
            ToolDescriptor(activeTitle: "Reading a file", doneTitle: "Read a file", symbol: "doc.text")
        case "write_file":
            ToolDescriptor(activeTitle: "Writing a file", doneTitle: "Wrote a file", symbol: "square.and.pencil")
        case "patch":
            ToolDescriptor(activeTitle: "Editing a file", doneTitle: "Edited a file", symbol: "pencil.line")
        case "search_files":
            ToolDescriptor(activeTitle: "Searching files", doneTitle: "Searched files", symbol: "doc.text.magnifyingglass")
        case "web_search":
            ToolDescriptor(activeTitle: "Searching the web", doneTitle: "Searched the web", symbol: "globe")
        case "x_search":
            ToolDescriptor(activeTitle: "Searching X", doneTitle: "Searched X", symbol: "magnifyingglass")
        case "web_extract":
            ToolDescriptor(activeTitle: "Reading a page", doneTitle: "Read a page", symbol: "doc.richtext")
        case "session_search":
            ToolDescriptor(activeTitle: "Searching past chats", doneTitle: "Searched past chats", symbol: "clock.arrow.circlepath")
        case "memory":
            ToolDescriptor(activeTitle: "Updating memory", doneTitle: "Updated memory", symbol: "brain")
        case "skill_view", "skills_list":
            ToolDescriptor(activeTitle: "Loading a skill", doneTitle: "Loaded a skill", symbol: "book.closed")
        case "skill_manage":
            ToolDescriptor(activeTitle: "Writing a skill", doneTitle: "Saved a skill", symbol: "book.closed")
        case "delegate_task":
            ToolDescriptor(activeTitle: "Delegating to subagents", doneTitle: "Delegated to subagents", symbol: "person.2")
        case "todo_list":
            ToolDescriptor(activeTitle: "Planning", doneTitle: "Updated the plan", symbol: "checklist")
        case "clarify":
            ToolDescriptor(activeTitle: "Asking a question", doneTitle: "Asked a question", symbol: "questionmark.bubble")
        case "image_generate":
            ToolDescriptor(activeTitle: "Generating an image", doneTitle: "Generated an image", symbol: "photo")
        case "video_generate":
            ToolDescriptor(activeTitle: "Generating a video", doneTitle: "Generated a video", symbol: "film")
        case "vision_analyze", "video_analyze", "browser_vision":
            ToolDescriptor(activeTitle: "Looking at an image", doneTitle: "Looked at an image", symbol: "eye")
        case "text_to_speech":
            ToolDescriptor(activeTitle: "Generating speech", doneTitle: "Generated speech", symbol: "waveform")
        case "cronjob_manage":
            ToolDescriptor(activeTitle: "Scheduling a task", doneTitle: "Scheduled a task", symbol: "calendar.badge.clock")
        case "computer_use":
            ToolDescriptor(activeTitle: "Using the computer", doneTitle: "Used the computer", symbol: "desktopcomputer")
        case "react_to_message", "start_chat":
            ToolDescriptor(activeTitle: "Messaging", doneTitle: "Sent a message", symbol: "paperplane")
        case "message_agent":
            // Bot Mode's agent-to-agent DM (tools/bot_mode_dm.py).
            ToolDescriptor(activeTitle: "Messaging a Bot", doneTitle: "Messaged a Bot", symbol: "paperplane")
        default:
            if name.hasPrefix("browser_") {
                ToolDescriptor(activeTitle: "Using the browser", doneTitle: "Used the browser", symbol: "safari")
            } else if name.hasPrefix("mcp_") {
                ToolDescriptor(activeTitle: "Calling \(prettify(name))", doneTitle: "Called \(prettify(name))", symbol: "puzzlepiece.extension")
            } else {
                ToolDescriptor(activeTitle: "Using \(prettify(name))", doneTitle: "Used \(prettify(name))", symbol: "wrench.and.screwdriver")
            }
        }
    }

    /// Turns `mcp_github_create_issue` into `github create issue`.
    static func prettify(_ name: String) -> String {
        var trimmed = Substring(name)
        if trimmed.hasPrefix("mcp_") { trimmed = trimmed.dropFirst(4) }
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }

    /// The most telling argument of a call, for one-line display.
    public static func argumentPreview(name: String, arguments: JSONValue?) -> String? {
        guard let arguments else { return nil }
        let preferredKeys = [
            "command", "query", "q", "url", "path", "file_path", "pattern", "goal", "prompt", "code", "name", "text", "message",
        ]
        for key in preferredKeys {
            if let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return String(value.prefix(240))
            }
        }
        if case .object(let object) = arguments, object.count == 1, let only = object.values.first?.stringValue {
            return String(only.prefix(240))
        }
        return nil
    }

    /// Heuristics Hermes Desktop uses to mark a tool result as an error.
    public static func looksLikeFailure(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("BLOCKED") { return true }
        guard trimmed.hasPrefix("{"), let json = JSONValue.parse(trimmed) else { return false }
        if let error = json["error"], error != .null, error.stringValue?.isEmpty != true { return true }
        if json["success"]?.boolValue == false { return true }
        if json["status"]?.stringValue == "error" { return true }
        if let exit = json["exit_code"]?.doubleValue, exit != 0 {
            let output = json["output"]?.stringValue ?? json["stdout"]?.stringValue ?? ""
            return output.isEmpty
        }
        return false
    }
}
