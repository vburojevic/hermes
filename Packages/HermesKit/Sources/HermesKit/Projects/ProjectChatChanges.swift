import Foundation

/// Chats this device archived from a project, or brought back with Undo, laid over what the
/// gateway last said (`docs/projects.md` §2). A project's chats come from `projects.tree` and
/// `projects.project_sessions`, which leave archived chats out, so without this an archived row
/// would stay until the next read and Undo would have no row to bring back until a read after
/// the unarchive. Each change holds until a read that started after it landed: that read
/// already has it, and from then on the gateway's answer is the truth. A change still in flight
/// is never dropped.
public struct ProjectChatChanges: Hashable, Sendable {
    public enum Change: Hashable, Sendable {
        case archived, restored
    }

    struct Entry: Hashable, Sendable {
        var change: Change
        /// Every id the chat goes by (stored id, lineage root).
        var ids: Set<String>
        var projectID: String
        var row: ProjectSessionRow
        /// Where the row sat, so Undo puts it back there: its folder, its lane (kept even when
        /// the gateway drops the lane with its last chat) and their places.
        var repoID: String?
        var lane: ProjectLane?
        var laneIndex = 0
        var rowIndex = 0
        var landedAt: Date?

        func matches(_ row: ProjectSessionRow) -> Bool {
            ids.contains(row.id) || ids.contains(row.stableID)
        }
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public func change(for key: String) -> Change? {
        entries[key]?.change
    }

    /// A chat's archive starts. Finds its row in the nodes given (a project's lanes first, then
    /// the tree's previews) and returns the project it was in, or `nil` when no project has it.
    @discardableResult
    public mutating func archiving(key: String, ids: Set<String>, in nodes: [ProjectNode]) -> String? {
        let ids = ids.union([key])
        if var entry = entries[key] {
            // Archived again before an earlier change was read back: keep where the row sat.
            entry.change = .archived
            entry.landedAt = nil
            entries[key] = entry
            return entry.projectID
        }
        for node in nodes {
            for repo in node.repos {
                for (laneIndex, lane) in repo.lanes.enumerated() {
                    guard let rowIndex = lane.sessions.firstIndex(where: { ids.contains($0.id) || ids.contains($0.stableID) }) else { continue }
                    var empty = lane
                    empty.sessions = []
                    entries[key] = Entry(change: .archived, ids: ids, projectID: node.id, row: lane.sessions[rowIndex],
                                         repoID: repo.id, lane: empty, laneIndex: laneIndex, rowIndex: rowIndex)
                    return node.id
                }
            }
        }
        for node in nodes {
            if let row = node.previewSessions.first(where: { ids.contains($0.id) || ids.contains($0.stableID) }) {
                entries[key] = Entry(change: .archived, ids: ids, projectID: node.id, row: row)
                return node.id
            }
        }
        return nil
    }

    /// Undo: the row comes back now, before its unarchive is sent.
    public mutating func restoring(key: String) {
        entries[key]?.change = .restored
        entries[key]?.landedAt = nil
    }

    /// The gateway stored a change. An archive that lands after its Undo leaves the Undo
    /// waiting for its own call.
    public mutating func landed(_ change: Change, key: String, at date: Date = .now) {
        guard entries[key]?.change == change else { return }
        entries[key]?.landedAt = date
    }

    /// The archive failed, or Undo came before an archive that then failed: nothing changed on
    /// the gateway, so its answer is right again.
    public mutating func forget(key: String) {
        entries[key] = nil
    }

    /// The unarchive failed after the archive had landed: the chat stays archived.
    public mutating func archivedAgain(key: String, at date: Date = .now) {
        entries[key]?.change = .archived
        entries[key]?.landedAt = date
    }

    /// A read of a project's chats that started at `startedAt` answered: the changes that had
    /// landed before it started are in its answer. An archive whose Undo still shows (`undoable`)
    /// stays: the read no longer has the row, and Undo needs it to put the row back at once.
    public mutating func read(projectID: String, startedAt: Date, keeping undoable: String? = nil) {
        entries = entries.filter { key, entry in
            guard entry.projectID == projectID, let landedAt = entry.landedAt else { return true }
            if key == undoable, entry.change == .archived { return true }
            return landedAt >= startedAt
        }
    }

    /// A node as it stands with these changes. `hydrated` is a project's lanes with their chats
    /// (`projects.project_sessions`); the tree's lanes carry none, so Undo only puts the row
    /// back in a hydrated node's lane.
    public func applied(to node: ProjectNode, hydrated: Bool) -> ProjectNode {
        var node = node
        for entry in entries.values.sorted(by: { $0.rowIndex < $1.rowIndex }) where entry.projectID == node.id {
            switch entry.change {
            case .archived: Self.remove(entry, from: &node)
            case .restored: Self.restore(entry, into: &node, hydrated: hydrated)
            }
        }
        return node
    }

    public func applied(to tree: ProjectTree) -> ProjectTree {
        guard !entries.isEmpty else { return tree }
        var tree = tree
        tree.nodes = tree.nodes.map { applied(to: $0, hydrated: false) }
        return tree
    }

    private static func remove(_ entry: Entry, from node: inout ProjectNode) {
        var removed = false
        for r in node.repos.indices {
            for l in node.repos[r].lanes.indices {
                let before = node.repos[r].lanes[l].sessions.count
                node.repos[r].lanes[l].sessions.removeAll(where: entry.matches)
                let gone = before - node.repos[r].lanes[l].sessions.count
                if gone > 0 {
                    removed = true
                    node.repos[r].sessionCount = max(0, node.repos[r].sessionCount - gone)
                }
            }
        }
        let previews = node.previewSessions.count
        node.previewSessions.removeAll(where: entry.matches)
        let ids = node.sessionIDs.count
        node.sessionIDs.removeAll { entry.ids.contains($0) }
        if removed || previews != node.previewSessions.count || ids != node.sessionIDs.count {
            node.sessionCount = max(0, node.sessionCount - 1)
        }
    }

    private static func restore(_ entry: Entry, into node: inout ProjectNode, hydrated: Bool) {
        let inLanes = node.hydratedSessions.contains(where: entry.matches)
        let known = inLanes || node.previewSessions.contains(where: entry.matches)
            || node.sessionIDs.contains { entry.ids.contains($0) }
        if hydrated, !inLanes, let lane = entry.lane, let r = node.repos.firstIndex(where: { $0.id == entry.repoID }) {
            if let l = node.repos[r].lanes.firstIndex(where: { $0.id == lane.id }) {
                let at = min(entry.rowIndex, node.repos[r].lanes[l].sessions.count)
                node.repos[r].lanes[l].sessions.insert(entry.row, at: at)
            } else {
                var lane = lane
                lane.sessions = [entry.row]
                node.repos[r].lanes.insert(lane, at: min(entry.laneIndex, node.repos[r].lanes.count))
            }
            node.repos[r].sessionCount += 1
        }
        guard !known else { return }
        node.sessionIDs.append(entry.row.id)
        node.sessionCount += 1
    }
}
