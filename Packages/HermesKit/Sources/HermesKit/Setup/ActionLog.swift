import Foundation

/// A long gateway job's output as the app shows it while it runs (`docs/setup.md` §4.2a): the
/// lines so far, the step running now, how it ended. Telegram gets the same lines from `/update`:
/// the gateway sends the new output every 4 s (`_watch_update_progress` in Hermes's
/// `gateway/run_notifications.py`). The app reads them from the dashboard, which starts these jobs
/// with their output in `~/.hermes/logs/<job>.log` and tails it at
/// `GET /api/actions/{name}/status?lines=N` (`hermes_cli/web_routers/actions.py`).
public struct ActionLog: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// "→ Pulling 12 commits", "↻ …", "☤ …", "⏳ …": something starting.
            case step
            /// "✓ Restarted ai.hermes.gateway".
            case done
            case warning
            case failure
            case plain
        }

        /// The line as Hermes printed it, without colour codes or a progress bar's earlier states.
        public var text: String
        public var kind: Kind
        /// Its words without the mark and the indent: "Pulling 12 commits".
        public var words: String
        /// Indented under the step before it.
        public var isDetail: Bool

        public init(_ printed: String) {
            text = printed
            let trimmed = printed.drop { $0 == " " || $0 == "\t" }
            isDetail = trimmed.count < printed.count
            let marks: [(String, Kind)] = [
                ("→", .step), ("↻", .step), ("☤", .step), ("⏳", .step),
                ("✓", .done), ("✅", .done), ("⚠️", .warning), ("⚠", .warning), ("✗", .failure), ("❌", .failure),
            ]
            if let (mark, kind) = marks.first(where: { trimmed.hasPrefix($0.0) }) {
                self.kind = kind
                words = String(trimmed.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            } else {
                self.kind = .plain
                words = String(trimmed)
            }
        }
    }

    /// This run's lines, oldest first, at most `limit`.
    public private(set) var lines: [Line] = []
    /// Whether the run's start header has been seen, so lines without one continue it.
    private var sawStart = false

    public static let limit = 2000

    public init() {}

    /// A log from one tail, as the first poll reads it.
    public init(tail: [String], name: String, actionID: String? = nil) {
        merge(tail: tail, name: name, actionID: actionID)
    }

    /// The step running now: the newest step line, without its mark.
    public var currentStep: String? {
        lines.last { $0.kind == .step && !$0.words.isEmpty }?.words ?? lines.last?.words
    }

    /// The newest line, as it reads on its own.
    public var lastLine: String? { lines.last?.words }

    /// Folds one poll's tail in. The file keeps every run of the job, each after its own
    /// `=== <name> started <time> [<action id>] ===` header, so only lines after this run's header
    /// count; the header with `actionID` when the run has one, the newest otherwise. Once a long
    /// run has pushed its header out of the tail, new lines continue from where the last poll's
    /// overlap with this one ends.
    public mutating func merge(tail: [String], name: String, actionID: String? = nil) {
        let cleaned = tail.map(Self.clean)
        let start = "=== \(name) started "
        let header = actionID.flatMap { id in cleaned.lastIndex { $0.hasPrefix(start) && $0.contains(id) } }
            ?? cleaned.lastIndex { $0.hasPrefix(start) }
        if let header {
            sawStart = true
            // Up to the next run's header, when this run is an older one.
            let next = cleaned[(header + 1)...].firstIndex { $0.hasPrefix(start) } ?? cleaned.endIndex
            lines = Array(Self.lines(Array(cleaned[(header + 1)..<next])).suffix(Self.limit))
            return
        }
        let incoming = Self.lines(cleaned)
        guard sawStart, !lines.isEmpty else {
            lines = Array(incoming.suffix(Self.limit))
            return
        }
        let overlap = Self.overlap(lines, incoming)
        lines.append(contentsOf: incoming.dropFirst(overlap))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    /// The longest run of lines that ends `old` and starts `new`.
    private static func overlap(_ old: [Line], _ new: [Line]) -> Int {
        var length = min(old.count, new.count)
        while length > 0 {
            if old.suffix(length).elementsEqual(new.prefix(length)) { return length }
            length -= 1
        }
        return 0
    }

    private static func lines(_ printed: [String]) -> [Line] {
        printed
            // The route's own markers ("=== hermes-update completed <id> ===") aren't output.
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("===") }
            .map(Line.init)
    }

    /// Without colour and cursor codes, and a line a progress bar redrew (`\r`) as it ended.
    static func clean(_ raw: String) -> String {
        var text = raw.replacing(/\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)/, with: "")
        text = text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
        text = text.replacing(/\u{1B}[@-Z\\-_]/, with: "")
        if let last = text.split(separator: "\r", omittingEmptySubsequences: true).last {
            text = String(last)
        } else {
            text = ""
        }
        while let end = text.last, end.isWhitespace { text.removeLast() }
        return text
    }
}

/// `GET /api/actions/{name}/status` for a job other than the update (`HermesUpdateStatus` reads
/// that one's receipt too): whether it still runs, how it exited, its log's tail.
public struct ActionStatus: Sendable, Equatable {
    public var running: Bool
    public var exitCode: Int?
    public var lines: [String]

    public init(json: JSONValue) {
        running = json["running"]?.boolValue ?? false
        exitCode = json["exit_code"]?.truncatedIntValue
        lines = json["lines"].items.compactMap(\.stringValue)
    }
}

/// A job's run as the app follows it: the update, a gateway restart.
public enum ActionRunState: Sendable, Equatable {
    case starting
    case running
    /// Exit 0.
    case succeeded
    case failed(exitCode: Int)
    /// Stopped answering for too long.
    case lostTouch
    /// The start itself failed: the request's error, in words.
    case couldNotStart(message: String)
}

extension BackendClient {
    /// A dashboard job's status and the last `lines` lines of its log (at most 2000).
    public func actionStatus(_ name: String, lines: Int = 200) async throws -> ActionStatus {
        ActionStatus(json: try await rest("api/actions/\(name)/status", query: [URLQueryItem(name: "lines", value: String(lines))]))
    }
}
