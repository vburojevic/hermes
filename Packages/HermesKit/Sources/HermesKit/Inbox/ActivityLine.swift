import Foundation
import HermesPush

/// What a chat is doing right now, in one line (`activityLine`, `docs/inbox.md` §2 The activity
/// line). The same line drives the row, the jump pill and the Live Activity; the app words it.
public enum ActivityLine: Hashable, Sendable {
    /// `session.active_list` status `starting`.
    case starting
    /// Working, no words yet.
    case thinking
    /// Working, with the newest words of the reply.
    case writing(String)
    /// A tool is running: its glyph and the step in plain words (chats the app is attached to).
    case tool(symbol: String, title: String, progress: PlanProgress?)
    /// Helpers out working (`subagent.*`).
    case helpers(Int)
    /// Hermes waits for the person.
    case waiting(NeedsYou)
    /// The last turn stopped: the reason, until the chat is opened.
    case failed(String)
    /// A Bot's routine is running ("Daily digest · thinking…").
    case routine(String)
    /// The person's message waits for the gateway, which hasn't taken it (away, or busy): "Waiting
    /// for <gateway>…", in still words. Hermes isn't working on it yet (`docs/chat.md` §4).
    case sending(gateway: String)

    /// What a paused turn waits for.
    public enum NeedsYou: Hashable, Sendable {
        case approval, question, key
    }

    /// The turn's checklist ("2 of 3").
    public struct PlanProgress: Hashable, Sendable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    /// Something is running (the live dot shows): every case but a failure.
    public var isLive: Bool {
        if case .failed = self { return false }
        return true
    }

    /// The words shimmer while Hermes works (`docs/chat.md` §4a). Waiting for the person or the
    /// gateway, and a stop, stay solid and still: nothing is working.
    public var shimmers: Bool {
        switch self {
        case .starting, .thinking, .writing, .tool, .helpers, .routine: true
        case .waiting, .failed, .sending: false
        }
    }

    /// The newest words of a reply, at most `limit` characters, from the start of a word, without
    /// Markdown's marks (`**`, `__`, backticks). Only the end of the text is read: it's asked four
    /// times a second while a reply streams, and walking the whole reply each time added up.
    public static func writingTail(_ text: String, limit: Int = 40) -> String {
        let recent = text.suffix(limit * 4 + 16)
        let cutBefore = recent.startIndex != text.startIndex
        let flat = recent.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        guard flat.count > limit || cutBefore else { return flat }
        let tail = flat.suffix(limit)
        // Cut mid-word: start at the next word.
        let midWord = tail.startIndex == flat.startIndex ? cutBefore : flat[flat.index(before: tail.startIndex)] != " "
        if midWord, let space = tail.firstIndex(of: " "), tail.index(after: space) < tail.endIndex {
            return "…" + tail[tail.index(after: space)...]
        }
        return "…" + tail
    }
}

extension ActivityLine {
    /// The face on a Bot's row follows what it's doing (`docs/bot-faces.md` §9): thinking while it
    /// starts or thinks, working while a tool runs or it writes, listening when it needs you,
    /// happy for a moment when a reply lands, asleep when muted and idle.
    /// - Parameter otherwise: the face it shows when nothing is happening (offline, hidden…).
    public static func faceMood(for line: ActivityLine?, justReplied: Bool, muted: Bool, otherwise: FaceMood) -> FaceMood {
        if justReplied { return .happy }
        switch line {
        case .waiting?: return .listening
        case .starting?, .thinking?, .routine?: return .thinking
        case .tool?, .helpers?, .writing?: return .working
        // Nothing works on a message the gateway hasn't taken: the face rests.
        case .failed?, .sending?, nil: return muted && otherwise == .idle ? .sleeping : otherwise
        }
    }
}

/// Follows one chat's `session.active_list` row across polls and turns it into an activity line
/// (`docs/inbox.md` §2). Hermes' `preview` is the prompt until the reply's first words, then the
/// words being written; a preview that changes while the chat is working is the reply.
public struct ActivityTracker: Sendable {
    public private(set) var line: ActivityLine?
    private var status = "idle"
    private var promptPreview: String?

    public init() {}

    /// Takes the row's latest status and preview. Returns whether the line changed.
    @discardableResult
    public mutating func update(status: String, preview: String?) -> Bool {
        let before = line
        let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasRunning = ["starting", "working", "waiting"].contains(self.status)
        switch status {
        case "starting":
            promptPreview = preview
            line = .starting
        case "working", "streaming", "resuming":
            if !wasRunning {
                // The first sight of a turn: the preview is the prompt (or, joined late, maybe
                // already the reply; it reads as thinking until it moves).
                promptPreview = preview
                line = .thinking
            } else if let preview, !preview.isEmpty, preview != promptPreview {
                line = .writing(ActivityLine.writingTail(preview))
            } else if case .writing = line {
                // Keep the words on screen.
            } else {
                line = .thinking
            }
        case "waiting":
            line = .waiting(.approval)
        default:
            promptPreview = nil
            line = nil
        }
        self.status = status
        return line != before
    }
}
