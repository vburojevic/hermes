import Foundation
import HermesKit
import Observation

/// The Files tab (`fileTreeRow`): the chat's folder as a tree, folders opened on demand, with each
/// changed file's git letter. `node_modules` and `.git` never show.
@MainActor
@Observable
final class FileTreeModel {
    @ObservationIgnored private weak var inspector: InspectorModel?
    let root: String
    private(set) var children: [String: [WorkspaceEntry]] = [:]
    var expanded: Set<String> = []
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var git: GitWorkingTree?
    /// The repository the root is in, for matching git's relative paths.
    private(set) var repoRoot: String?

    static let hidden: Set<String> = ["node_modules", ".git", ".DS_Store"]

    init(inspector: InspectorModel, root: String) {
        self.inspector = inspector
        self.root = root
        expanded = [root]
    }

    var name: String { ProjectPath.lastComponent(root) }

    func loadIfNeeded() async {
        if children[root] == nil { await refresh() }
    }

    func refresh() async {
        await list(root)
        for path in expanded where path != root { await list(path) }
        await loadGit()
    }

    func toggle(_ entry: WorkspaceEntry) {
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            if children[entry.path] == nil { Task { await list(entry.path) } }
        }
    }

    private func list(_ path: String) async {
        guard let backend = inspector?.backend else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            let listing = try await backend.listFolder(path, profile: inspector?.profile)
            if let error = listing.error { errors[path] = error } else { errors[path] = nil }
            children[path] = listing.entries.filter { !Self.hidden.contains($0.name) }
        } catch {
            errors[path] = error.localizedDescription
        }
    }

    private func loadGit() async {
        guard let backend = inspector?.backend else { return }
        repoRoot = try? await backend.gitRoot(of: root, profile: inspector?.profile)
        git = repoRoot == nil ? nil : (try? await backend.gitStatus(root))
    }

    /// The git letter for a file (`M`, `A`, `D`, `U` for a conflict), if it changed.
    func letter(for path: String) -> String? {
        guard let git, let repoRoot, path.hasPrefix(repoRoot) else { return nil }
        let relative = String(path.dropFirst(repoRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return git.file(relative)?.letter
    }

    /// Rows in display order: (entry, depth).
    var rows: [(entry: WorkspaceEntry, depth: Int)] {
        var out: [(WorkspaceEntry, Int)] = []
        func walk(_ path: String, _ depth: Int) {
            for entry in children[path] ?? [] {
                out.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) { walk(entry.path, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    /// Opens the folders down to a file, so the tree shows it selected.
    func reveal(_ path: String) async {
        guard path.hasPrefix(root) else { return }
        var folder = (path as NSString).deletingLastPathComponent
        var chain: [String] = []
        while folder.count > root.count {
            chain.insert(folder, at: 0)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for path in chain where !expanded.contains(path) {
            expanded.insert(path)
            if children[path] == nil { await list(path) }
        }
    }
}

/// A File tab (`docs/inspector.md` §2): the text from `/api/fs/read-text`, edited here and saved
/// with `/api/fs/write-text`. Saving reads the file again first; a change made on the gateway
/// meanwhile asks Reload or Keep Mine.
@MainActor
@Observable
final class FileEditorModel {
    enum Conflict: Equatable {
        /// The gateway's copy changed since this one was opened.
        case changedOnGateway(theirs: String)
    }

    @ObservationIgnored private weak var inspector: InspectorModel?
    let path: String
    var text = ""
    private(set) var original = ""
    private(set) var language: String?
    private(set) var isTruncated = false
    private(set) var isBinary = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var loadError: String?
    var saveError: String?
    var conflict: Conflict?
    private(set) var hasLoaded = false
    /// The editor's caret line (1-based), for the status line.
    var caretLine = 1
    /// Saved this session, so the status line says Hermes sees it next turn.
    private(set) var savedOnce = false

    init(inspector: InspectorModel, path: String) {
        self.inspector = inspector
        self.path = path
    }

    var name: String { ProjectPath.lastComponent(path) }
    var isEdited: Bool { hasLoaded && text != original }
    var isEditable: Bool { hasLoaded && !isTruncated && !isBinary }

    /// Lines changed since the file was opened or saved.
    var changedLines: Int {
        guard isEdited else { return 0 }
        let a = original.components(separatedBy: "\n"), b = text.components(separatedBy: "\n")
        let difference = b.difference(from: a)
        return max(difference.insertions.count, difference.removals.count)
    }

    func loadIfNeeded() async {
        if !hasLoaded, !isLoading { await load() }
    }

    func load() async {
        guard let backend = inspector?.backend else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await backend.readText(path, profile: inspector?.profile)
            language = file.language
            isTruncated = file.truncated
            isBinary = file.binary
            original = file.text
            text = file.text
            loadError = nil
            hasLoaded = true
        } catch {
            loadError = Self.describe(error)
        }
    }

    /// Reads the gateway's copy, then writes this one unless it changed meanwhile.
    func save(force: Bool = false) async {
        guard let backend = inspector?.backend, isEditable else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if !force {
                let current = try await backend.readText(path, profile: inspector?.profile)
                if current.text != original {
                    conflict = .changedOnGateway(theirs: current.text)
                    return
                }
            }
            try await backend.writeText(path, content: text, profile: inspector?.profile)
            original = text
            conflict = nil
            saveError = nil
            savedOnce = true
            inspector?.fileSaved(path)
        } catch {
            saveError = Self.describe(error)
        }
    }

    /// Reload: the gateway's copy replaces this one.
    func takeTheirs() {
        guard case .changedOnGateway(let theirs) = conflict else { return }
        original = theirs
        text = theirs
        conflict = nil
    }

    /// Keep Mine: write this copy over the gateway's.
    func keepMine() async {
        await save(force: true)
    }

    /// Hermes changed the file during a turn: reload it unless it's being edited here.
    func gatewayChanged() async {
        guard hasLoaded, !isEdited else { return }
        await load()
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? HermesError {
            switch error {
            case .requestTooLarge, .server(413, _, _): return String(localized: "This file is too big to open here.")
            case .server(415, _, _): return String(localized: "This file isn't text.")
            case .server(_, _, let message?) where !message.isEmpty: return message
            default: break
            }
        }
        return error.localizedDescription
    }
}
