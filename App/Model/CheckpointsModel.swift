import HermesKit
import SwiftUI

/// One chat's checkpoints (`docs/checkpoints.md`): which replies can be undone, what they changed,
/// and going back. Hermes saves the chat's folder before a turn's first file write; the gateway
/// keeps them per folder (`rollback.*`), so the list can include other chats in the same folder.
///
/// Gateway behaviour this leans on (verified in `tui_gateway/methods_tools.py` and
/// `tools/checkpoint_manager.py`):
/// - A whole-folder restore always drops only the chat's newest turn; going back further, this
///   drops the later turns one by one (`session.undo`) so the chat matches the files.
/// - It overwrites the files but leaves files created after the checkpoint.
/// - Every restore first saves the files as they were ("pre-rollback snapshot"), so it can be
///   undone from the timeline; the chat can't.
/// - Hashes change when Hermes prunes old checkpoints: list again before acting.
@MainActor
@Observable
final class CheckpointsModel {
    /// What's on screen.
    enum Sheet: Identifiable, Hashable {
        /// `reviewChanges`: what a reply changed.
        case review(turnID: String)
        /// `undoConfirm`: Undo a reply, or Restore All for a checkpoint.
        case confirm(Target)
        /// `checkpointsTimeline` (iPhone) or `macCheckpoints`, optionally on one checkpoint.
        case timeline(selected: String?)
        /// `checkpointsOffSheet`.
        case off

        var id: String {
            switch self {
            case .review(let turnID): "review-\(turnID)"
            case .confirm(let target): "confirm-\(target.checkpoint.id)"
            case .timeline: "timeline"
            case .off: "off"
            }
        }
    }

    /// What Undo or Restore All goes back to.
    struct Target: Hashable {
        let checkpoint: Checkpoint
        /// Set when it is a reply's Undo.
        var turnID: String?
    }

    @ObservationIgnored private weak var conversation: ConversationModel?

    var sheet: Sheet?
    private(set) var list: CheckpointList?
    private(set) var isLoading = false
    private(set) var loadFailure: String?
    /// Diffs by `stableKey`, since hashes change when Hermes prunes.
    private(set) var diffs: [String: CheckpointDiff] = [:]
    private(set) var diffFailures: [String: String] = [:]
    /// What's going out: `all:<key>`, `file:<key>:<path>`, `on`.
    private(set) var working: Set<String> = []
    /// Files restored here, `<key>:<path>`, so their rows say so.
    private(set) var restoredFiles: Set<String> = []
    @ObservationIgnored private var restoredOrder: [String] = []
    /// The gateway refused for this chat and said why (a chat in a container).
    private(set) var refusal: String?
    /// Turn On worked: checkpoints start with the next turn that edits files.
    private(set) var justTurnedOn = false
    /// Turn On couldn't reach the setting: show the command to run on the gateway.
    private(set) var turnOnFailed = false
    var alert: String?

    @ObservationIgnored private var lastLoaded: Date?
    @ObservationIgnored private var reattachWhenIdle = false

    init(conversation: ConversationModel) {
        self.conversation = conversation
    }

    private var client: CheckpointsClient? {
        guard let roster = conversation?.gatewayRosterForCheckpoints, roster.isConnected else { return nil }
        return CheckpointsClient { method, params in try await roster.request(method, params) }
    }

    // MARK: Reading

    /// The chat runs over the gateway protocol, where `rollback.*` live (Bot Mode).
    var isAvailable: Bool { conversation?.usesGateway == true }
    var isOnline: Bool { conversation?.gatewayRosterForCheckpoints?.isConnected == true }
    /// `nil` until the gateway has said.
    var isEnabled: Bool? { list?.enabled }
    var checkpoints: [Checkpoint] { list?.checkpoints ?? [] }
    var gatewayName: String { conversation?.workspace?.bot.name ?? String(localized: "the gateway") }

    var matcher: CheckpointMatcher { CheckpointMatcher(items: conversation?.rows ?? []) }

    /// Newest first, one row per turn.
    var timeline: [Checkpoint] { matcher.timeline(checkpoints) }

    /// A turn runs: a whole-folder restore waits (the gateway refuses it, 4009).
    var chatIsWorking: Bool { conversation?.isWorking ?? false }

    /// The state before a reply, when Hermes saved one.
    func checkpoint(beforeTurn turnID: String) -> Checkpoint? {
        guard let list, list.enabled else { return nil }
        return undoPoints(list)[turnID]
    }

    @ObservationIgnored private var undoPointCache: (key: Int, points: [String: Checkpoint])?

    /// Each reply's earliest checkpoint, worked out once per list and transcript.
    private func undoPoints(_ list: CheckpointList) -> [String: Checkpoint] {
        let matcher = matcher
        var hasher = Hasher()
        hasher.combine(list)
        hasher.combine(matcher.spans)
        let key = hasher.finalize()
        if let undoPointCache, undoPointCache.key == key { return undoPointCache.points }
        var points: [String: Checkpoint] = [:]
        for checkpoint in list.checkpoints {
            guard let turnID = matcher.span(of: checkpoint)?.turnID else { continue }
            if let earlier = points[turnID], (earlier.date ?? .distantPast) <= (checkpoint.date ?? .distantPast) { continue }
            points[turnID] = checkpoint
        }
        undoPointCache = (key, points)
        return points
    }

    /// The newest reply that changed files (⌥⌘Z, and the reply menu's Undo File Changes…). Its
    /// Undo opens the off sheet when checkpoints are off.
    var latestEditingTurnID: String? {
        for item in (conversation?.rows ?? []).reversed() {
            guard case .assistant(let turn) = item else { continue }
            if !TurnFileEdits(turn: turn).isEmpty { return turn.id }
        }
        return nil
    }

    /// The reply's own edits, for its bar.
    func edits(in turn: AssistantTurn) -> TurnFileEdits { TurnFileEdits(turn: turn) }

    /// Hashes change when Hermes prunes; the time and message don't.
    static func stableKey(_ checkpoint: Checkpoint) -> String {
        "\(checkpoint.date?.timeIntervalSince1970 ?? 0)|\(checkpoint.message)"
    }

    func diff(for checkpoint: Checkpoint) -> CheckpointDiff? { diffs[Self.stableKey(checkpoint)] }
    func diffFailure(for checkpoint: Checkpoint) -> String? { diffFailures[Self.stableKey(checkpoint)] }

    func isWorking(_ key: String) -> Bool { working.contains(key) }
    func allKey(_ checkpoint: Checkpoint) -> String { "all:\(Self.stableKey(checkpoint))" }
    func fileKey(_ checkpoint: Checkpoint, _ path: String) -> String { "file:\(Self.stableKey(checkpoint)):\(path)" }
    /// Files restored here from `checkpoint`, in the order they were.
    func restoredPaths(from checkpoint: Checkpoint) -> [String] {
        let prefix = "\(Self.stableKey(checkpoint)):"
        return restoredOrder.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    func wasRestored(_ path: String, from checkpoint: Checkpoint) -> Bool {
        restoredFiles.contains("\(Self.stableKey(checkpoint)):\(path)")
    }

    /// "~/Code/hermes-app": the chat's folder, home shortened.
    var folder: String? {
        guard let cwd = conversation?.liveWorkspace?.cwd else { return nil }
        return Self.shortened(cwd)
    }

    var branch: String? { conversation?.liveWorkspace?.branch }

    static func shortened(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0].isEmpty, ["Users", "home"].contains(parts[1]) {
            return (["~"] + parts.dropFirst(3)).joined(separator: "/")
        }
        if path.hasPrefix("/root") { return "~" + path.dropFirst("/root".count) }
        return path
    }

    // MARK: Words

    /// "14:31", "Yesterday 18:40", "Oct 12, 18:40".
    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// "Before “Fix the reconnect after sleep”", or what else Hermes saved it for.
    func title(for checkpoint: Checkpoint) -> String {
        if let span = matcher.span(of: checkpoint) {
            return String(localized: "Before “\(Self.oneLine(span.text))”")
        }
        switch checkpoint.kind {
        case .beforeRestore(let target):
            if let restored = checkpoints.first(where: { $0.hash.hasPrefix(target) }) {
                return String(localized: "Before going back to \(Self.time(restored.date))")
            }
            return String(localized: "Before a restore")
        case .beforeCommand(let command):
            return String(localized: "Before “\(Self.oneLine(command))”")
        case .beforeEdit:
            return String(localized: "Before a file edit in another chat")
        case .other(let text):
            return text
        }
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    // MARK: Loading

    /// Lists the folder's checkpoints. Skipped when it ran a moment ago, unless `force`.
    func refresh(force: Bool = false) async {
        guard let conversation, isAvailable else { return }
        if !force, let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 2 { return }
        if reattachWhenIdle, !conversation.isWorking {
            reattachWhenIdle = false
            await conversation.reattachForSettings()
        }
        guard let client, let runtime = await conversation.runtimeForCheckpoints() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.list(sessionID: runtime)
            lastLoaded = .now
            if fresh != list { list = fresh }
            loadFailure = nil
            if fresh.enabled { justTurnedOn = justTurnedOn && fresh.checkpoints.isEmpty }
        } catch {
            loadFailure = CheckpointFailure(error: error).map(Self.sentence) ?? error.localizedDescription
        }
    }

    /// What differs between a checkpoint and the files now.
    func loadDiff(_ checkpoint: Checkpoint, force: Bool = false) async {
        let key = Self.stableKey(checkpoint)
        guard force || diffs[key] == nil, let conversation, let client else { return }
        guard let runtime = await conversation.runtimeForCheckpoints() else { return }
        do {
            let diff = try await client.diff(sessionID: runtime, hash: try await currentHash(of: checkpoint, runtime: runtime))
            diffs[key] = diff
            diffFailures[key] = nil
            refusal = nil
        } catch {
            let failure = CheckpointFailure(error: error)
            if case .refused(let reason)? = failure { refusal = reason }
            diffFailures[key] = failure.map(Self.sentence) ?? error.localizedDescription
        }
    }

    /// The checkpoint's hash now: listed again, matched by time and message.
    private func currentHash(of checkpoint: Checkpoint, runtime: String) async throws -> String {
        guard let client else { return checkpoint.hash }
        let fresh = try await client.list(sessionID: runtime)
        if fresh != list { list = fresh }
        let key = Self.stableKey(checkpoint)
        return fresh.checkpoints.first { Self.stableKey($0) == key }?.hash ?? checkpoint.hash
    }

    static func sentence(_ failure: CheckpointFailure) -> String {
        switch failure {
        case .busy: String(localized: "Hermes is still working. You can undo when it stops.")
        case .refused(let reason): reason
        }
    }

    // MARK: Acting

    /// Opens Undo for a reply, or what stands in its way.
    func undo(turnID: String) {
        if list?.enabled == false {
            sheet = .off
        } else if let checkpoint = checkpoint(beforeTurn: turnID) {
            sheet = .confirm(Target(checkpoint: checkpoint, turnID: turnID))
        } else {
            sheet = .timeline(selected: nil)
        }
    }

    /// Opens the timeline, or the off sheet.
    func showTimeline(selecting checkpoint: Checkpoint? = nil) {
        sheet = list?.enabled == false ? .off : .timeline(selected: checkpoint.map(Self.stableKey))
    }

    /// The replies restoring `checkpoint` takes out of the chat, oldest first.
    func turnsRemoved(restoring checkpoint: Checkpoint) -> [CheckpointMatcher.Span] {
        matcher.turnsRemoved(restoring: checkpoint)
    }

    /// Undo or Restore All: the folder back to `target`, and the chat back to before its turn.
    func restoreAll(_ target: Target) async {
        guard let conversation else { return }
        guard isOnline, let client else {
            alert = String(localized: "\(gatewayName) is offline. Undo when it's back.")
            return
        }
        guard !conversation.isWorking else {
            alert = Self.sentence(.busy)
            return
        }
        let key = allKey(target.checkpoint)
        working.insert(key)
        defer { working.remove(key) }
        let removed = turnsRemoved(restoring: target.checkpoint)
        guard let runtime = await conversation.runtimeForCheckpoints() else { return }
        do {
            let hash = try await currentHash(of: target.checkpoint, runtime: runtime)
            if diff(for: target.checkpoint) == nil { await loadDiff(target.checkpoint) }
            let before = diff(for: target.checkpoint)
            let result = try await client.restore(sessionID: runtime, hash: hash)
            guard result.success else {
                if let error = result.error { refusal = error }
                alert = result.error ?? String(localized: "Hermes couldn't put the files back.")
                return
            }
            // The gateway dropped the newest turn; the rest go one by one.
            var dropped = removed.isEmpty ? 0 : 1
            for _ in removed.dropFirst() {
                do {
                    try await client.dropLastTurn(sessionID: runtime)
                    dropped += 1
                } catch {
                    break
                }
            }
            let first = removed.count - dropped
            let note = Self.note(result: result, diff: before, at: target.checkpoint.date, turns: dropped, planned: removed.count)
            sheet = nil
            conversation.applyUndo(
                from: removed.indices.contains(first) ? removed[first].userID : nil,
                note: note,
                returning: removed.indices.contains(first) ? removed[first].text : nil
            )
            diffs = [:]
            diffFailures = [:]
            await refresh(force: true)
        } catch {
            if let failure = CheckpointFailure(error: error) {
                if case .refused(let reason) = failure { refusal = reason }
                alert = Self.sentence(failure)
            } else {
                alert = error.localizedDescription
            }
        }
    }

    /// One file back as it was at `checkpoint`; the chat and the other files stay. Works while
    /// Hermes is busy.
    func restoreFile(_ file: CheckpointFileChange, from checkpoint: Checkpoint) async {
        guard let conversation, isOnline, let client, file.pathIsExact else { return }
        let key = fileKey(checkpoint, file.path)
        working.insert(key)
        defer { working.remove(key) }
        guard let runtime = await conversation.runtimeForCheckpoints() else { return }
        do {
            let hash = try await currentHash(of: checkpoint, runtime: runtime)
            let result = try await client.restore(sessionID: runtime, hash: hash, filePath: file.path)
            guard result.success else {
                alert = result.error ?? String(localized: "Hermes couldn't restore \(file.fileName).")
                return
            }
            let restored = "\(Self.stableKey(checkpoint)):\(file.path)"
            restoredOrder.removeAll { $0 == restored }
            restoredOrder.append(restored)
            restoredFiles.insert(restored)
            await refresh(force: true)
            await loadDiff(checkpoint, force: true)
        } catch {
            alert = CheckpointFailure(error: error).map(Self.sentence) ?? error.localizedDescription
        }
    }

    /// Turn On Checkpoints: the profile's config, then this chat reattached so its agent reads it.
    func turnOn() async {
        guard let conversation, let roster = conversation.gatewayRosterForCheckpoints else { return }
        working.insert("on")
        defer { working.remove("on") }
        do {
            try await roster.setCheckpointsEnabled(true, profile: conversation.gatewayProfileForCheckpoints)
            turnOnFailed = false
        } catch {
            turnOnFailed = true
            return
        }
        justTurnedOn = true
        if conversation.isWorking {
            reattachWhenIdle = true
        } else {
            await conversation.reattachForSettings()
        }
        await refresh(force: true)
        if list?.enabled == true, case .off? = sheet { sheet = .timeline(selected: nil) }
    }

    /// The command that turns checkpoints on, for when the app can't.
    var turnOnCommand: String { "hermes config set checkpoints.enabled true" }

    // MARK: Notes

    /// `restoredNote`: what the restore did, then what it kept or couldn't do.
    static func note(result: CheckpointRestoreResult, diff: CheckpointDiff?, at date: Date?, turns: Int, planned: Int) -> RestoredNote {
        let files = diff?.files ?? []
        let created = files.filter { $0.change == .created }
        let restoredCount = result.restoredFiles.isEmpty ? files.count - created.count : result.restoredFiles.count
        let time = Self.time(date)
        var title: String = switch (restoredCount, turns) {
        case (0, _): String(localized: "Put the files back to before \(time)")
        case (1, _): String(localized: "Restored 1 file to before \(time)")
        default: String(localized: "Restored \(restoredCount) files to before \(time)")
        }
        switch turns {
        case 0: break
        case 1: title += String(localized: " and removed that turn")
        default: title += String(localized: " and removed \(turns) turns")
        }
        var details: [String] = []
        for path in result.skippedOversize {
            details.append(String(localized: "Kept \(path): too large to checkpoint."))
        }
        for path in result.skippedUserEdits {
            details.append(String(localized: "Kept \(path): you edited it after Hermes did."))
        }
        // `hermes serve` overwrites without deleting: files made since are still there.
        if result.restoredFiles.isEmpty, result.failedDeletes.isEmpty, !created.isEmpty {
            let names = created.map(\.fileName).formatted(.list(type: .and))
            details.append(created.count == 1
                ? String(localized: "\(names) is still there: Hermes doesn't delete files it created.")
                : String(localized: "\(names) are still there: Hermes doesn't delete files it created."))
        }
        var warnings: [String] = []
        if !result.failedDeletes.isEmpty {
            warnings.append(String(localized: "Couldn't delete \(result.failedDeletes.formatted(.list(type: .and)))."))
        }
        if turns < planned {
            let left = planned - turns
            warnings.append(left == 1
                ? String(localized: "1 earlier turn stayed in the chat: Hermes couldn't remove it.")
                : String(localized: "\(left) earlier turns stayed in the chat: Hermes couldn't remove them."))
        }
        return RestoredNote(title: title, details: details, warnings: warnings)
    }
}

/// What a restore did, shown where the turn was (`restoredNote`).
struct RestoredNote: Hashable {
    var title: String
    /// Kept files and similar, in grey.
    var details: [String]
    /// What failed, in orange.
    var warnings: [String]
}
