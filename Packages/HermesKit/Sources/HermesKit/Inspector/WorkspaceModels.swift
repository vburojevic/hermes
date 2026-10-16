import Foundation

// The Inspector's Files, File and Changes tabs (`docs/inspector.md` §2), over the backend's
// `/api/fs/*` and `/api/git/*` (`hermes_cli/web_routers/files.py`, `git.py`). File contents are
// the person's: never log them.

/// One entry of a folder (`GET /api/fs/list`). The gateway hides `node_modules`, `.git` and
/// sensitive files.
public struct WorkspaceEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// A folder's listing; `error` is the errno name (`ENOENT`, `EACCES`) when it couldn't be read.
public struct WorkspaceListing: Sendable, Hashable {
    public var entries: [WorkspaceEntry]
    public var error: String?

    init(json: JSONValue) {
        let entries: [WorkspaceEntry] = json["entries"].items.compactMap { row in
            guard let path = row["path"]?.stringValue else { return nil }
            return WorkspaceEntry(name: row["name"]?.stringValue ?? ProjectPath.lastComponent(path), path: path,
                                  isDirectory: row["isDirectory"]?.boolValue ?? false)
        }
        self.init(entries: entries, error: json["error"]?.stringValue)
    }

    public init(entries: [WorkspaceEntry], error: String? = nil) {
        self.entries = entries
        self.error = error
    }
}

/// A text file (`GET /api/fs/read-text`): the first 512 KB when it's bigger (`truncated`).
public struct WorkspaceText: Sendable, Hashable {
    public var path: String
    public var text: String
    /// The gateway's language name for highlighting ("typescript", "python", "text").
    public var language: String
    public var mimeType: String
    public var byteSize: Int
    public var truncated: Bool
    public var binary: Bool

    public init(path: String, text: String, language: String = "text", mimeType: String = "text/plain", byteSize: Int = 0,
                truncated: Bool = false, binary: Bool = false) {
        self.path = path
        self.text = text
        self.language = language
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.truncated = truncated
        self.binary = binary
    }

    init(json: JSONValue, path: String) {
        self.init(
            path: json["path"]?.stringValue ?? path,
            text: json["text"]?.stringValue ?? "",
            language: json["language"]?.stringValue ?? "text",
            mimeType: json["mimeType"]?.stringValue ?? "text/plain",
            byteSize: json["byteSize"]?.doubleValue.map { Int($0) } ?? 0,
            truncated: json["truncated"]?.boolValue ?? false,
            binary: json["binary"]?.boolValue ?? false
        )
    }
}

/// A repository's working tree (`GET /api/git/status`): the branch and each changed file.
public struct GitWorkingTree: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        public var path: String
        public var staged: Bool
        public var unstaged: Bool
        public var untracked: Bool
        public var conflicted: Bool

        /// The letter the tree shows: A for new, M for changed, U for conflicted.
        public var letter: String {
            if conflicted { return "U" }
            if untracked { return "A" }
            return "M"
        }
    }

    public var branch: String?
    public var defaultBranch: String?
    public var ahead: Int
    public var behind: Int
    public var changed: Int
    public var added: Int
    public var removed: Int
    /// Paths relative to the repository root.
    public var files: [File]

    init?(json: JSONValue) {
        guard case .object = json else { return nil }
        branch = json["branch"]?.stringValue
        defaultBranch = json["defaultBranch"]?.stringValue
        ahead = json["ahead"]?.doubleValue.map { Int($0) } ?? 0
        behind = json["behind"]?.doubleValue.map { Int($0) } ?? 0
        changed = json["changed"]?.doubleValue.map { Int($0) } ?? 0
        added = json["added"]?.doubleValue.map { Int($0) } ?? 0
        removed = json["removed"]?.doubleValue.map { Int($0) } ?? 0
        files = json["files"].items.compactMap { row in
            guard let path = row["path"]?.stringValue else { return nil }
            return File(path: path, staged: row["staged"]?.boolValue ?? false, unstaged: row["unstaged"]?.boolValue ?? false,
                        untracked: row["untracked"]?.boolValue ?? false, conflicted: row["conflicted"]?.boolValue ?? false)
        }
    }

    /// A file's status by its path relative to the root.
    public func file(_ relativePath: String) -> File? {
        files.first { $0.path == relativePath }
    }
}

/// Which changes Changes shows (`GET /api/git/review/list?scope=`).
public enum ReviewScope: String, Sendable, Hashable, CaseIterable {
    /// Since the turn started: the gateway diffs from the commit recorded then.
    case lastTurn
    /// The branch since it left its base.
    case branch
    /// What isn't committed (staged and not).
    case uncommitted
}

/// One changed file in a review (`changeRow`).
public struct ReviewFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var added: Int
    public var removed: Int
    /// `M`, `A`, `D`, `R`, `?` (new, untracked), `U` (conflicted).
    public var status: String
    public var staged: Bool
    public var id: String { path }

    public init(path: String, added: Int, removed: Int, status: String, staged: Bool) {
        self.path = path
        self.added = added
        self.removed = removed
        self.status = status
        self.staged = staged
    }

    /// The letter the row shows: new files read as A.
    public var letter: String { status == "?" ? "A" : status }
}

public struct ReviewList: Sendable, Hashable {
    public var files: [ReviewFile]
    /// The base commit the scope diffs against, when it has one.
    public var base: String?

    init(json: JSONValue) {
        files = json["files"].items.compactMap { row in
            guard let path = row["path"]?.stringValue else { return nil }
            return ReviewFile(path: path, added: row["added"]?.doubleValue.map { Int($0) } ?? 0,
                              removed: row["removed"]?.doubleValue.map { Int($0) } ?? 0,
                              status: row["status"]?.stringValue ?? "M", staged: row["staged"]?.boolValue ?? false)
        }
        base = json["base"]?.stringValue
    }

    public init(files: [ReviewFile], base: String? = nil) {
        self.files = files
        self.base = base
    }

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

/// Whether a pull request can be made, and the branch's open one (`GET /api/git/review/ship-info`).
public struct ShipInfo: Sendable, Hashable {
    public var ghReady: Bool
    public var pullRequestURL: URL?
    public var pullRequestNumber: Int?
    /// `OPEN`, `MERGED` or `CLOSED`.
    public var pullRequestState: String?

    /// The branch has a pull request still open (Create Pull Request opens it instead).
    public var openPullRequest: URL? {
        pullRequestState?.uppercased() == "OPEN" ? pullRequestURL : nil
    }

    init(json: JSONValue) {
        ghReady = json["ghReady"]?.boolValue ?? false
        pullRequestURL = json["pr"]?["url"]?.stringValue.flatMap(URL.init(string:))
        pullRequestNumber = json["pr"]?["number"]?.doubleValue.map { Int($0) }
        pullRequestState = json["pr"]?["state"]?.stringValue
    }
}

/// `gh` on the gateway (`GET /api/git/gh-auth`).
public struct GitHubAuth: Sendable, Hashable {
    public var available: Bool
    public var authenticated: Bool
}
