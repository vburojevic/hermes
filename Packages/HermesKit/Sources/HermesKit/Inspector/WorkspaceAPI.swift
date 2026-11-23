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

    /// A picture to show whole (`GET /api/fs/download`), held in memory only. A file over
    /// `MediaViewing.maxBytes` throws `MediaTooBig` before its bytes are read: by `knownSize` (the
    /// listing's size) when the caller has it, otherwise by a `HEAD`'s `Content-Length`
    /// (docs/widgets.md §9.2).
    public func downloadPicture(_ path: String, profile: String? = nil, knownSize: Int64? = nil) async throws -> (Data, String?) {
        let query = Self.query(["path": path, "profile": profile])
        var size = knownSize
        if size == nil {
            let (_, head) = try await restResponse("api/fs/download", method: "HEAD", query: query)
            size = head.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        }
        if let size, size > MediaViewing.maxBytes { throw MediaTooBig(bytes: size) }
        let (data, type) = try await restData("api/fs/download", query: query)
        // A server that gave no size is still held to the limit once it has answered.
        if Int64(data.count) > MediaViewing.maxBytes { throw MediaTooBig(bytes: Int64(data.count)) }
        return (data, type)
    }

    /// A file's size without its bytes: the `Content-Length` of a `HEAD` of `/api/fs/download`.
    /// Nil when the gateway doesn't say, or doesn't answer `HEAD` (405). Throws its refusals: 404
    /// for a file that's gone, 403 for one Hermes keeps private (`MediaProblem.of`).
    public func fileSize(_ path: String, profile: String? = nil) async throws -> Int64? {
        do {
            let (_, head) = try await restResponse("api/fs/download", method: "HEAD", query: Self.query(["path": path, "profile": profile]))
            return head.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        } catch Failure.http(405, _) {
            return nil
        }
    }

    /// A file's bytes to save a copy of, held in memory only until it's saved: refused before
    /// they're read when the file is over `limit` (`MediaTooBig`), by a `HEAD`'s size or, when
    /// the gateway gave none, once it has answered.
    public func downloadCopy(_ path: String, profile: String? = nil, limit: Int64) async throws -> Data {
        if let size = try await fileSize(path, profile: profile), size > limit { throw MediaTooBig(bytes: size) }
        let (data, _) = try await restData("api/fs/download", query: Self.query(["path": path, "profile": profile]))
        if Int64(data.count) > limit { throw MediaTooBig(bytes: Int64(data.count)) }
        return data
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
    /// `display.observe` gave, on this backend's own session so it never follows a redirect to
    /// another server. The caller resumes it.
    public func displaySocket(ticket: String, path: String = "api/display/ws") -> URLSessionWebSocketTask {
        let socket = webSocketTask(with: displaySocketURL(ticket: ticket, path: path))
        socket.maximumMessageSize = 64 * 1024 * 1024
        return socket
    }

    func displaySocketURL(ticket: String, path: String = "api/display/ws") -> URL {
        var components = URLComponents(url: baseURL.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        return components.url!
    }
}
