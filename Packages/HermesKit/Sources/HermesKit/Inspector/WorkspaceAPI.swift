import Foundation

// The Inspector's REST calls (`docs/inspector.md` §2). Paths are the gateway machine's; a Bot's
// files are read through its profile (`?profile=`).

extension BackendClient {
    private static func query(_ items: [String: String?]) -> [URLQueryItem] {
        items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }.sorted { $0.name < $1.name }
    }

    // MARK: Files

    /// A folder's entries, folders first (`GET /api/fs/list`).
    public func listFolder(_ path: String, profile: String? = nil) async throws -> WorkspaceListing {
        WorkspaceListing(json: try await rest("api/fs/list", query: Self.query(["path": path, "profile": profile])))
    }

    /// A text file, the first 512 KB of it (`GET /api/fs/read-text`). Refuses files over its cap
    /// (413) and binaries read as text.
    public func readText(_ path: String, profile: String? = nil) async throws -> WorkspaceText {
        WorkspaceText(json: try await rest("api/fs/read-text", query: Self.query(["path": path, "profile": profile])), path: path)
    }

    /// Writes a text file whole (`POST /api/fs/write-text`): the parent must exist. Catching a
    /// change made meanwhile is the caller's job (read again before saving).
    public func writeText(_ path: String, content: String, profile: String? = nil) async throws {
        _ = try await rest("api/fs/write-text", method: "POST", query: Self.query(["profile": profile]),
                           body: .object(["path": .string(path), "content": .string(content)]))
    }

    /// A file's bytes and type (`GET /api/fs/download`), for a page's images, scripts and styles.
    public func downloadFile(_ path: String, profile: String? = nil) async throws -> (Data, String?) {
        try await restData("api/fs/download", query: Self.query(["path": path, "profile": profile]))
    }

    /// The repository a path is in (`GET /api/fs/git-root`); nil outside one.
    public func gitRoot(of path: String, profile: String? = nil) async throws -> String? {
        try await rest("api/fs/git-root", query: Self.query(["path": path, "profile": profile]))["root"]?.stringValue
    }

    // MARK: Git

    /// The working tree's branch and changed files (`GET /api/git/status`); nil outside a repo.
    public func gitStatus(_ path: String) async throws -> GitWorkingTree? {
        GitWorkingTree(json: try await rest("api/git/status", query: Self.query(["path": path])))
    }

    /// The changed files for a scope (`GET /api/git/review/list`). This Turn needs the commit the
    /// turn started from (`base`).
    public func reviewList(_ path: String, scope: ReviewScope, base: String? = nil) async throws -> ReviewList {
        ReviewList(json: try await rest("api/git/review/list", query: Self.query(["path": path, "scope": scope.rawValue, "base": base])))
    }

    /// One file's unified diff in a scope (`GET /api/git/review/diff`).
    public func reviewDiff(_ path: String, file: String, scope: ReviewScope, base: String? = nil, staged: Bool = false) async throws -> String {
        let query = Self.query(["path": path, "file": file, "scope": scope.rawValue, "base": base, "staged": staged ? "true" : nil])
        return try await rest("api/git/review/diff", query: query)["diff"]?.stringValue ?? ""
    }

    /// The commit HEAD points at (`GET /api/git/review/rev-parse`), recorded when a turn starts.
    public func revParse(_ path: String, ref: String? = nil) async throws -> String? {
        try await rest("api/git/review/rev-parse", query: Self.query(["path": path, "ref": ref]))["sha"]?.stringValue
    }

    public func stage(_ path: String, file: String?) async throws {
        _ = try await rest("api/git/review/stage", method: "POST", body: Self.fileBody(path, file))
    }

    public func unstage(_ path: String, file: String?) async throws {
        _ = try await rest("api/git/review/unstage", method: "POST", body: Self.fileBody(path, file))
    }

    /// Commits what's staged with the message (`POST /api/git/review/commit`), pushing after when
    /// asked. A refusal throws git's words.
    public func commit(_ path: String, message: String, push: Bool) async throws {
        _ = try await rest("api/git/review/commit", method: "POST", body: .object([
            "path": .string(path), "message": .string(message), "push": .bool(push),
        ]))
    }

    public func push(_ path: String) async throws {
        _ = try await rest("api/git/review/push", method: "POST", body: .object(["path": .string(path)]))
    }

    /// Pushes and opens a pull request with `gh pr create --fill` (`POST /api/git/review/create-pr`);
    /// its URL, or gh's reason.
    public func createPullRequest(_ path: String) async throws -> URL? {
        try await rest("api/git/review/create-pr", method: "POST", body: .object(["path": .string(path)]))["url"]?.stringValue.flatMap(URL.init(string:))
    }

    /// Whether a pull request can be made here, and the branch's open one.
    public func shipInfo(_ path: String) async throws -> ShipInfo {
        ShipInfo(json: try await rest("api/git/review/ship-info", query: Self.query(["path": path])))
    }

    /// `gh` on the gateway (`GET /api/git/gh-auth`): installed, signed in.
    public func gitHubAuth(refresh: Bool = false) async throws -> GitHubAuth {
        let json = try await rest("api/git/gh-auth", query: refresh ? [URLQueryItem(name: "refresh", value: "true")] : [])
        return GitHubAuth(available: json["available"]?.boolValue ?? false, authenticated: json["authenticated"]?.boolValue ?? false)
    }

    /// What a commit message is drafted from (`GET /api/git/review/commit-context`): the staged
    /// diff and recent subjects.
    public func commitContext(_ path: String) async throws -> (diff: String, recent: String) {
        let json = try await rest("api/git/review/commit-context", query: Self.query(["path": path]))
        return (json["diff"]?.stringValue ?? "", json["recent"]?.stringValue ?? "")
    }

    private static func fileBody(_ path: String, _ file: String?) -> JSONValue {
        var body: [String: JSONValue] = ["path": .string(path)]
        if let file { body["file"] = .string(file) }
        return .object(body)
    }

    // MARK: Bot Screen

    /// The Bot Screen's RFB socket (`WS /api/display/ws?display_ticket=`), from a ticket
    /// `display.observe` gave.
    public func displaySocketURL(ticket: String, path: String = "api/display/ws") -> URL {
        var components = URLComponents(url: baseURL.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        return components.url!
    }
}
