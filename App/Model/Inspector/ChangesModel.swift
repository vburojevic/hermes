import Foundation
import HermesKit
import Observation

/// The Changes tab (`changeRow`, `shipBar`): the repository's changes in a scope (This Turn,
/// Branch, Uncommitted), one file's diff, staging, and shipping them: commit with the message,
/// push, open a pull request. Errors show inline, in git's or gh's words.
@MainActor
@Observable
final class ChangesModel {
    @ObservationIgnored private weak var inspector: InspectorModel?
    /// The folder the chat works in; git runs in the repository around it.
    let root: String
    var scope = ReviewScope.lastTurn {
        didSet { if scope != oldValue { Task { await refresh() } } }
    }
    private(set) var list: ReviewList?
    private(set) var isLoading = false
    private(set) var loadError: String?
    var selectedFile: String? {
        didSet { if selectedFile != oldValue { Task { await loadDiff() } } }
    }
    private(set) var diff: String?
    private(set) var git: GitWorkingTree?
    private(set) var ship: ShipInfo?
    private(set) var gitHub: GitHubAuth?
    /// What the shipBar sends: a subject line, then a body.
    var message = ""
    private(set) var isDrafting = false
    private(set) var draftedByHermes = false
    private(set) var isShipping = false
    var shipError: String?
    /// The pull request just made, to open.
    private(set) var pullRequestURL: URL?
    /// Files staged or unstaged here while the call runs.
    private(set) var busyFiles: Set<String> = []

    init(inspector: InspectorModel, root: String) {
        self.inspector = inspector
        self.root = root
    }

    var files: [ReviewFile] { list?.files ?? [] }
    var stagedCount: Int { files.filter(\.staged).count }

    /// "feature/beta-page → main · 3 of 4 files staged".
    var branchLine: String? {
        guard let git, let branch = git.branch else { return nil }
        var line = branch
        if let base = git.defaultBranch, base != branch { line += " → \(base)" }
        return line
    }

    /// Whether This Turn has a starting point (the commit when the turn began).
    var turnBase: String? { inspector?.turnBase }

    func loadIfNeeded() async {
        if list == nil, !isLoading { await refresh() }
    }

    func refresh() async {
        guard let backend = inspector?.backend else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let base = scope == .lastTurn ? turnBase : nil
            if scope == .lastTurn, base == nil {
                // No turn has started here since the app opened the chat: show what's uncommitted.
                list = try await backend.reviewList(root, scope: .uncommitted)
            } else {
                list = try await backend.reviewList(root, scope: scope, base: base)
            }
            loadError = nil
            if selectedFile == nil || !files.contains(where: { $0.path == selectedFile }) {
                selectedFile = files.first?.path
            } else {
                await loadDiff()
            }
        } catch {
            loadError = FileEditorModel.describe(error)
        }
        git = try? await backend.gitStatus(root)
        ship = try? await backend.shipInfo(root)
        if gitHub == nil { gitHub = try? await backend.gitHubAuth() }
    }

    private func loadDiff() async {
        guard let backend = inspector?.backend, let file = selectedFile else {
            diff = nil
            return
        }
        let effective: ReviewScope = scope == .lastTurn && turnBase == nil ? .uncommitted : scope
        diff = try? await backend.reviewDiff(root, file: file, scope: effective, base: effective == .lastTurn ? turnBase : nil)
    }

    func toggleStaged(_ file: ReviewFile) async {
        guard let backend = inspector?.backend else { return }
        busyFiles.insert(file.path)
        defer { busyFiles.remove(file.path) }
        do {
            if file.staged {
                try await backend.unstage(root, file: file.path)
            } else {
                try await backend.stage(root, file: file.path)
            }
            shipError = nil
        } catch {
            shipError = FileEditorModel.describe(error)
        }
        await refresh()
    }

    // MARK: Shipping

    /// Hermes drafts the message from the staged diff and recent subjects (`llm.oneshot`,
    /// `commit_message`), with the chat's model. Asked for, never automatic.
    func draftMessage() async {
        guard let backend = inspector?.backend, let roster = inspector?.workspace?.roster else { return }
        isDrafting = true
        defer { isDrafting = false }
        do {
            let context = try await backend.commitContext(root)
            guard !context.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                shipError = String(localized: "Stage a file first: Hermes drafts the message from what's staged.")
                return
            }
            var params: [String: JSONValue] = [
                "template": .string("commit_message"), "temperature": .number(0.8),
                "variables": .object(["avoid": .string(message), "diff": .string(context.diff), "recent_commits": .string(context.recent)]),
            ]
            if let session = inspector?.conversation?.runtimeSessionID { params["session_id"] = .string(session) }
            if let profile = inspector?.profile { params["profile"] = .string(profile) }
            let result = try await roster.request("llm.oneshot", params, timeout: .seconds(90))
            if let text = result["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                message = text
                draftedByHermes = true
                shipError = nil
            }
        } catch {
            shipError = FileEditorModel.describe(error)
        }
    }

    func edited() { draftedByHermes = false }

    /// Commit and Push.
    func commitAndPush() async {
        await shipping { backend in
            try await backend.commit(self.root, message: self.message, push: true)
            self.message = ""
            self.draftedByHermes = false
        }
    }

    /// Create Pull Request: commits what's staged when there's a message, pushes, then `gh pr
    /// create --fill`. An open pull request on the branch opens instead.
    func createPullRequest() async {
        if let url = ship?.openPullRequest {
            pullRequestURL = url
            return
        }
        await shipping { backend in
            if !self.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.stagedCount > 0 {
                try await backend.commit(self.root, message: self.message, push: false)
                self.message = ""
                self.draftedByHermes = false
            }
            self.pullRequestURL = try await backend.createPullRequest(self.root)
        }
    }

    func consumePullRequestURL() -> URL? {
        defer { pullRequestURL = nil }
        return pullRequestURL
    }

    /// Why Create Pull Request can't work here, if it can't (`/api/git/gh-auth`).
    var pullRequestBlocker: String? {
        guard let gitHub else { return nil }
        let machine = inspector?.gatewayMachineName ?? String(localized: "the gateway")
        if !gitHub.available { return String(localized: "Install the GitHub CLI (gh) on \(machine) to create pull requests.") }
        if !gitHub.authenticated { return String(localized: "Sign in to GitHub on \(machine)") }
        return nil
    }

    var canCommit: Bool {
        stagedCount > 0 && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isShipping
    }

    private func shipping(_ work: @escaping (BackendClient) async throws -> Void) async {
        guard let backend = inspector?.backend else { return }
        isShipping = true
        defer { isShipping = false }
        do {
            try await work(backend)
            shipError = nil
        } catch {
            shipError = FileEditorModel.describe(error)
        }
        await refresh()
    }
}
