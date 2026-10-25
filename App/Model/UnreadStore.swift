import Foundation
import HermesKit
import HermesPush
import os

/// What's new in one gateway's chats, Bots and group chats (`docs/inbox.md` §1): each row's
/// badge, the read marks shared with other devices, mutes, and where each chat was left.
///
/// Chats are keyed by session (its stable key), Bots as `bot:<name>`, group chats as
/// `group:<id>`. Read marks come from Hermes' dashboard rows (`last_read_at`) when Bot Mode is
/// linked; a gateway without them keeps a watermark on this device, as `BotRoster` does, and
/// then read state doesn't sync. Counts are the app's own, cached so the list draws at once.
@Observable
final class UnreadStore {
    /// What each row shows. Only rows with something to show have an entry.
    private(set) var badges: [String: UnreadBadge] = [:]
    private(set) var mutes: MuteList
    /// Each row's last message, as the rows read it: only a line that changed redraws them.
    /// Hermes' list rows carry the first message, never the last, so the app reads it itself
    /// (`book`).
    private(set) var lastLines: [String: LastLine] = [:]
    /// The lines with the chat activity each was read at, kept on the device (`docs/inbox.md` §2).
    @ObservationIgnored private var book = LastLineBook()
    @ObservationIgnored private var bookSave: Task<Void, Never>?

    @ObservationIgnored weak var workspace: BotWorkspace?
    @ObservationIgnored private let gatewayID: UUID
    @ObservationIgnored private var cache: Cache
    /// Hermes keeps read marks for this gateway's chats (its dashboard answered).
    @ObservationIgnored private var hasGatewayMarks = false
    /// Marks and counts this device just changed, until Hermes' rows catch up (a list fetched
    /// before the edit landed must not undo it).
    @ObservationIgnored private var pending: [String: (mark: ReadMark, at: Date)] = [:]
    /// Chats whose mark is on its way to the gateway: theirs holds until the call is back (a busy
    /// Mac takes far longer than the 10 s a mark otherwise holds), so a list read meanwhile
    /// doesn't bring the badge back.
    @ObservationIgnored private var sending: [String: Int] = [:]
    @ObservationIgnored private var countedAt: [String: Date] = [:]
    @ObservationIgnored private var counting: Set<String> = []
    @ObservationIgnored private var countRetry: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var muteTimer: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var listRefresh: Task<Void, Never>?
    @ObservationIgnored private var listRefreshedAt = Date.distantPast
    /// Chats whose last line was asked for, at the activity it was asked at.
    @ObservationIgnored private var lineAsked: [String: Date] = [:]
    @ObservationIgnored private var lineFetches = 0
    /// How far each chat being opened was read, taken just before opening marks anything read.
    @ObservationIgnored private var openings: [String: Opening] = [:]

    /// Where a chat with something new was read up to when it opened (`docs/inbox.md` §4).
    struct Opening: Equatable {
        /// Hermes' read mark, when it's a time.
        var since: Date?
        /// The last row this device showed.
        var seenThrough: String?
    }
    @ObservationIgnored private lazy var recheck = ReadRecheck { [weak self] now in self?.fetchMarks(now: now) }
    /// Reads that didn't reach the gateway (busy, offline): they go when it answers (`ReadOutbox`).
    @ObservationIgnored private lazy var outbox: ReadOutbox = {
        guard let data = UserDefaults.standard.data(forKey: outboxKey) else { return ReadOutbox() }
        return (try? JSONDecoder().decode(ReadOutbox.self, from: data)) ?? ReadOutbox()
    }()
    @ObservationIgnored private var outboxFlush: Task<Void, Never>?
    private var outboxKey: String { "readOutbox.\(gatewayID.uuidString)" }

    init(gatewayID: UUID) {
        self.gatewayID = gatewayID
        #if DEBUG
        // `-HERMES_RESET_INBOX YES`: start from nothing (UI tests).
        if UserDefaults.standard.bool(forKey: "HERMES_RESET_INBOX") {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey(gatewayID))
        }
        #endif
        let cache = (UserDefaults.standard.data(forKey: Self.cacheKey(gatewayID))).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        self.cache = cache
        var mutes = cache.mutes
        mutes.prune()
        self.mutes = mutes
        hasGatewayMarks = !cache.marks.isEmpty
        restoreLastLines()
    }

    /// Everything kept on the device, per gateway. Never message text: ids, times and counts.
    private struct Cache: Codable {
        struct Count: Codable, Equatable {
            var value: Int
            /// The chat's activity and read mark it was counted at.
            var lastActive: Double
            var since: Double
        }

        var counts: [String: Count] = [:]
        /// Hermes' marks as last fetched, so the list draws them before the first fetch.
        var marks: [String: ReadMark] = [:]
        /// A gateway without read marks: the activity seen when each chat was last read here.
        var watermarks: [String: Double] = [:]
        var mutes = MuteList()
        /// The last row shown on this device, per chat (the New Messages line resumes after it).
        var seen: [String: String] = [:]
        /// The row at the top of a chat left scrolled up.
        var scroll: [String: String] = [:]
    }

    private static func cacheKey(_ id: UUID) -> String { "inbox.\(id.uuidString)" }

    // MARK: Keys

    static func botKey(_ name: String) -> String { "bot:\(name)" }
    static func groupKey(_ id: String) -> String { "group:\(id)" }

    /// The chat on screen: never unread, and read as it's shown.
    var openKey: String? {
        switch workspace?.selection {
        case .session(let key): key
        case .bot(let name): Self.botKey(name)
        case .group(let id): Self.groupKey(id)
        default: nil
        }
    }

    // MARK: Reading

    func badge(for key: String) -> UnreadBadge {
        badges[key] ?? .none
    }

    func isMuted(_ key: String) -> Bool {
        mutes.isMuted(key)
    }

    /// Hermes' read mark for a chat as this device knows it, for the New Messages line. Without
    /// Hermes' marks, this device's (a watermark of 0 is marked unread).
    func readMark(for key: String) -> ReadMark? {
        if let pending = pending[key] { return pending.mark }
        if hasGatewayMarks, let mark = cache.marks[key] { return mark }
        return cache.watermarks[key].map { $0 == 0 ? .markedUnread : .readUntil(Date(timeIntervalSince1970: $0)) }
    }

    /// Unread chats (not messages) that aren't muted or hidden Bots, leaving out the open one.
    func unreadChats(in keys: some Sequence<String>) -> Int {
        let open = openKey
        let hidden = hiddenBots
        return keys.reduce(0) { total, key in
            counts(key, open: open, hidden: hidden) ? total + 1 : total
        }
    }

    /// Bots folded under "Hidden · N": they count like muted ones (`BadgeScope`).
    private var hiddenBots: Set<String> {
        Set(workspace?.roster?.hiddenBots.map(\.name) ?? [])
    }

    private func counts(_ key: String, open: String?, hidden: Set<String>) -> Bool {
        BadgeScope.counts(key, isUnread: badge(for: key).isUnread, open: open, isMuted: mutes.isMuted(key), hiddenBots: hidden)
    }

    /// Every unread, unmuted chat, Bot and group chat but the open one (the drawer button).
    var unreadElsewhere: Int {
        unreadChats(in: badges.keys)
    }

    /// Unread Bots and group chats (the Bots segment), or chats (the Chats segment).
    func unreadCount(inBots: Bool) -> Int {
        unreadChats(in: badges.keys.filter { ($0.hasPrefix("bot:") || $0.hasPrefix("group:")) == inBots })
    }

    // MARK: Updating

    /// The chat list, Hermes' marks, the open chat or a count moved: every badge again.
    func update() {
        guard let workspace else { return }
        let open = openKey
        var next: [String: UnreadBadge] = [:]
        var marksSeeded = false
        for session in workspace.sessions {
            let key = session.stableID
            guard key != open, let active = session.lastActive else { continue }
            guard let mark = readMark(for: key) ?? (hasGatewayMarks ? .untracked : nil) else {
                // First sight on a gateway without marks: what's there is read.
                cache.watermarks[key] = active.timeIntervalSince1970
                marksSeeded = true
                continue
            }
            if let badge = badge(for: key, mark: mark, lastActive: active, session: session) { next[key] = badge }
        }
        if let roster = workspace.roster {
            for name in roster.unread where Self.botKey(name) != open {
                if roster.markedUnread.contains(name) {
                    next[Self.botKey(name)] = .dot
                } else if let badge = botBadge(name, roster: roster) {
                    next[Self.botKey(name)] = badge
                }
            }
            for (id, count) in roster.groupRooms.unreadCounts where Self.groupKey(id) != open && count > 0 {
                next[Self.groupKey(id)] = .count(count)
            }
        }
        if next != badges { badges = next }
        if marksSeeded { scheduleSave() }
        readStaleLines()
        #if HERMES_PUSH
        // The app icon (or Dock) badge counts them when the person chose Unread Chats; a mute moves
        // it without moving a row, so it's recorded every time (unchanged costs nothing).
        PushCenter.shared.unreadChanged(badgeChats(), countable: countableChats(), gateway: gatewayID)
        // Whatever moved may have read a chat with notifications still on the Lock Screen.
        PushCenter.shared.readMayHaveMoved(in: workspace)
        #endif
    }

    private func badge(for key: String, mark: ReadMark, lastActive: Date, session: HermesSession) -> UnreadBadge? {
        switch mark {
        case .untracked:
            return nil
        case .markedUnread:
            return .dot
        case .readUntil(let read):
            guard mark.isUnread(lastActive: lastActive) else { return nil }
            let cached = cache.counts[key]
            let fresh = cached.map { $0.since == read.timeIntervalSince1970 && $0.lastActive >= lastActive.timeIntervalSince1970 } ?? false
            if !fresh, !isRunning(key) { scheduleCount(key) { [weak self] in try await self?.countChat(session, since: read) } }
            // Until it's counted again, the last count stands (no flicker as replies land).
            guard let value = cached?.value, value > 0 else { return nil }
            return .count(value)
        }
    }

    private func botBadge(_ name: String, roster: BotRoster) -> UnreadBadge? {
        let key = Self.botKey(name)
        guard let bot = roster.bot(named: name), let active = bot.chatActivity, let chat = bot.canonicalSession else { return nil }
        let since = roster.readPoint(name) ?? .distantPast
        let cached = cache.counts[key]
        let fresh = cached.map { $0.since == since.timeIntervalSince1970 && $0.lastActive >= active.timeIntervalSince1970 } ?? false
        if !fresh, !isRunning(key) {
            scheduleCount(key) { [weak self] in
                guard let client = self?.workspace?.roster?.boardClient else { return nil }
                let transcript = try await client.transcript(storedSessionID: chat.resolvedID, profile: name, limit: 100)
                let tally = await Self.tally(transcript.messages, hidesSilence: true, after: since)
                self?.noteLastLine(key, tally.lastLine, asOf: active)
                return Cache.Count(value: tally.count, lastActive: active.timeIntervalSince1970, since: since.timeIntervalSince1970)
            }
        }
        guard let value = cached?.value, value > 0 else { return nil }
        return .count(value)
    }

    private func countChat(_ session: HermesSession, since: Date) async throws -> Cache.Count? {
        guard let client = workspace?.client, let active = session.lastActive else { return nil }
        let transcript = try await client.transcript(sessionID: session.id, limit: 100)
        let tally = await Self.tally(transcript.messages, hidesSilence: false, after: since)
        workspace?.activity.lastTurn(of: session.stableID, failed: tally.failedTurn)
        noteLastLine(session.stableID, tally.lastLine, asOf: active)
        return Cache.Count(value: tally.count, lastActive: active.timeIntervalSince1970, since: since.timeIntervalSince1970)
    }

    /// A chat whose turn is still running: only replies that end a turn count, so it's counted
    /// once it stops, not with every heartbeat that moves its row while it streams.
    private func isRunning(_ key: String) -> Bool {
        workspace?.activity.line(for: key)?.isLive == true
    }

    /// What a count needs from a chat's newest rows. Built off the main actor: 100 rows of
    /// transcript take a few milliseconds, and came up every 2 s for each chat that changed.
    private struct Tally: Sendable {
        let count: Int
        let lastLine: LastLine?
        /// The `failed_turn` notice the chat ends on, if it does.
        let failedTurn: String?
    }

    @concurrent
    private nonisolated static func tally(_ messages: [SessionMessage], hidesSilence: Bool, after since: Date) async -> Tally {
        let items = TranscriptBuilder.build(messages, hidesSilence: hidesSilence)
        let failed: String? = if case .notice(let notice)? = items.last, notice.kind == "failed_turn" { notice.text } else { nil }
        return Tally(count: UnreadCounter.count(items, after: since), lastLine: LastLine.of(items), failedTurn: failed)
    }

    /// Counts a row again, at most every 2 s (`docs/inbox.md` §1 Counting).
    private func scheduleCount(_ key: String, _ count: @escaping () async throws -> Cache.Count?) {
        guard !counting.contains(key) else { return }
        let wait = 2 - Date.now.timeIntervalSince(countedAt[key] ?? .distantPast)
        guard wait <= 0 else {
            retryCountsSoon(after: wait)
            return
        }
        counting.insert(key)
        countedAt[key] = .now
        Task { [weak self] in
            let result = try? await count()
            guard let self else { return }
            self.counting.remove(key)
            guard let result else { return }
            if self.cache.counts[key] != result {
                self.cache.counts[key] = result
                self.scheduleSave()
            }
            self.update()
        }
    }

    private func retryCountsSoon(after wait: TimeInterval) {
        guard countRetry == nil else { return }
        countRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait + 0.05))
            guard let self, !Task.isCancelled else { return }
            self.countRetry = nil
            self.update()
        }
    }

    // MARK: Last lines

    /// The lines this device kept, shown at once; the rows whose chat moved on since are read again.
    private func restoreLastLines() {
        Task { [weak self, gatewayID] in
            guard let kept = await LastLinesCache.load(gatewayID), let self else { return }
            self.book.merge(kept)
            let lines = self.book.entries.mapValues(\.line)
            if lines != self.lastLines {
                self.lastLines = lines
                self.workspace?.roster?.reorder()
            }
            LaunchTrace.mark("kept last lines shown (\(lines.count))", id: "kept last lines")
            self.readStaleLines()
        }
    }

    /// A row's last message, read at the chat's activity `asOf` (the open chat's: when it showed).
    /// An older read than the line there changes nothing (`LastLineBook`).
    func noteLastLine(_ key: String, _ line: LastLine?, asOf: Date) {
        let before = book.entries[key]
        let changed = book.note(key, line, asOf: asOf)
        guard book.entries[key] != before else { return }
        if changed, let line {
            lastLines[key] = line
            // A Bot's row sorts by its line's time (`RowTime`); the chats sort as they're drawn.
            if key.hasPrefix("bot:") { workspace?.roster?.reorder() }
            LaunchTrace.mark("last line \(key) (\(lastLines.count) rows have one)", id: "line \(key)")
            LoadTrace.mark(key, "row's last line now \(line.speaker), \(line.text.count) characters")
        }
        guard bookSave == nil else { return }
        bookSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.bookSave = nil
            LastLinesCache.save(self.gatewayID, book: self.book)
        }
    }

    /// Rows whose chat moved on since their last line was read, or that have none: their newest
    /// few rows, the Bots, the most recent chats and each project's newest few first (the rest as
    /// they come on screen, `needsLastLine`), since a project's time is its chats'
    /// (`ProjectsModel.rowTime`). A chat in the middle of a turn shows what it's doing instead, and
    /// is read once it stops.
    func readStaleLines() {
        guard let workspace, lineFetches < lineFetchLimit else { return }
        if let roster = workspace.roster {
            for bot in roster.visibleBots {
                let key = Self.botKey(bot.name)
                guard !isRunning(key), book.isStale(key, activity: bot.chatActivity) else { continue }
                needsBotLine(bot)
            }
        }
        for session in workspace.sessions.prefix(Self.linesReadAhead) {
            let key = session.stableID
            guard !isRunning(key), book.isStale(key, activity: session.lastActive) else { continue }
            needsLastLine(session)
        }
        for row in (workspace.projects?.tree.explicitProjects ?? []).flatMap(\.previewSessions) {
            guard !isRunning(row.stableID), book.isStale(row.stableID, activity: row.lastActive) else { continue }
            needsLastLine(row.session)
        }
    }

    /// The chats near the top whose last lines are read before they come on screen.
    private static let linesReadAhead = 20
    /// Reads at a time: one while the gateway's Mac is busy, so they don't hold up the open chat.
    private var lineFetchLimit: Int {
        workspace?.isBusy == true || workspace?.roster?.isBusy == true ? 1 : 4
    }

    /// A row came on screen without its last message, or its chat moved on: the chat's newest few
    /// rows, once per activity, a few at a time.
    func needsLastLine(_ session: HermesSession) {
        // A waiting chat's row says what it waits for; Hermes may not have the chat yet.
        guard let client = workspace?.client, workspace?.waitingChat(forKey: session.stableID) == nil else { return }
        readLine(session.stableID, activity: session.lastActive) {
            let transcript = try await client.transcript(sessionID: session.id, limit: 8)
            return LastLine.of(TranscriptBuilder.build(transcript.messages))
        }
    }

    private func needsBotLine(_ bot: BotProfile) {
        guard let chat = bot.canonicalSession, let client = workspace?.roster?.boardClient else { return }
        readLine(Self.botKey(bot.name), activity: bot.chatActivity) {
            let transcript = try await client.transcript(storedSessionID: chat.resolvedID, profile: bot.name, limit: 8)
            return LastLine.of(TranscriptBuilder.build(transcript.messages, hidesSilence: true))
        }
    }

    private func readLine(_ key: String, activity: Date?, _ read: @escaping () async throws -> LastLine?) {
        guard let activity, lineAsked[key].map({ $0 < activity }) ?? true, lineFetches < lineFetchLimit else { return }
        lineAsked[key] = activity
        lineFetches += 1
        Task { [weak self] in
            do {
                let line = try await read()
                guard let self else { return }
                self.lineFetches -= 1
                self.noteLastLine(key, line, asOf: activity)
                self.readStaleLines()
            } catch {
                // Asked again at the next change to the lists, not straight away.
                self?.lineFetches -= 1
                self?.lineAsked[key] = nil
            }
        }
    }

    // MARK: Notifications

    /// How far the chat a notification is about was read, by what this device knows
    /// (`docs/notifications.md` §2 Reading): the chat on screen while the app is in front, now; a
    /// read chat, through its newest activity seen here and a little after (the plugin stamps a
    /// notice just after the reply lands); an unread one, through its mark. Nil keeps it.
    func readThrough(_ chat: ReadNotices.Chat) -> Date? {
        guard let workspace else { return nil }
        let slack: TimeInterval = 10
        let open = BotRoster.isInFront ? openKey : nil
        if let room = chat.room {
            if Self.groupKey(room) == open { return .now }
            guard let rooms = workspace.roster?.groupRooms, let read = rooms.readAt(room) else { return nil }
            return rooms.unreadCounts[room] == nil ? read.addingTimeInterval(slack) : read
        }
        let botChats = workspace.roster?.botChats ?? [:]
        if let roster = workspace.roster, let profile = chat.profile ?? chat.ids.lazy.compactMap({ botChats[$0] }).first {
            if Self.botKey(profile) == open { return .now }
            guard let point = roster.readPoint(profile) else { return nil }
            if roster.unread.contains(profile) { return point }
            return max(point, roster.bot(named: profile)?.chatActivity ?? point).addingTimeInterval(slack)
        }
        guard let session = workspace.sessions.first(where: { chat.ids.contains($0.id) || chat.ids.contains($0.stableID) })
        else { return nil }
        let key = session.stableID
        if key == open { return .now }
        guard let mark = readMark(for: key), let read = mark.readUntil else { return nil }
        if mark.isUnread(lastActive: session.lastActive) { return read }
        return max(read, session.lastActive ?? read).addingTimeInterval(slack)
    }

    /// The chats the app icon badge counts (`PushShared.recordUnread`): unread, unmuted, not on
    /// screen, not a hidden Bot, named every way a notice may name them.
    func badgeChats() -> [UnreadChat] {
        guard let workspace else { return [] }
        let open = openKey
        let hidden = hiddenBots
        let botChats = workspace.roster?.botChats ?? [:]
        return badges.keys.sorted().compactMap { key -> UnreadChat? in
            guard counts(key, open: open, hidden: hidden) else { return nil }
            if key.hasPrefix("bot:") {
                let name = String(key.dropFirst(4))
                return UnreadChat(key: key, ids: botChats.filter { $0.value == name }.keys.sorted(),
                                  since: workspace.roster?.bot(named: name)?.chatActivity ?? .now)
            }
            if key.hasPrefix("group:") {
                let id = String(key.dropFirst(6))
                return UnreadChat(key: key, room: id, since: workspace.roster?.groupRooms.room(id)?.updatedAt ?? .now)
            }
            guard let session = workspace.session(forKey: key) else { return nil }
            return UnreadChat(key: key, ids: Array(Set([session.id, key])).sorted(), since: session.lastActive ?? .now)
        }
    }

    /// Every chat, Bot and group chat the app lists for this gateway: the badge never counts
    /// anything else (a notice for a routine's run or a Bot-to-Bot one-shot chat), nor a hidden
    /// Bot's. Nil until the list has loaded, so a cold start doesn't wipe what the badge knew.
    func countableChats() -> CountableChats? {
        guard let workspace, !workspace.sessions.isEmpty || workspace.roster?.profiles.isEmpty == false else { return nil }
        let hidden = hiddenBots
        var ids: Set<String> = []
        for session in workspace.sessions {
            ids.insert(session.id)
            ids.insert(session.stableID)
        }
        let botChats = workspace.roster?.botChats ?? [:]
        // A hidden Bot's own chat leaves the list's sessions too (the primary Bot's is one of them).
        ids.subtract(botChats.filter { hidden.contains($0.value) }.keys)
        ids.formUnion(BadgeScope.countedBotChats(botChats, hiddenBots: hidden).keys)
        return CountableChats(ids: ids, bots: Set(workspace.roster?.profiles.map(\.name) ?? []).subtracting(hidden),
                              rooms: Set(workspace.roster?.groupRooms.rooms.map(\.id) ?? []),
                              unmarked: namesUnmarked ? Set(unmarkedSessions().flatMap { [$0.id, $0.stableID] }) : [])
    }

    /// Against an older push plugin, which counts never-marked chats, the extension counts them too.
    private var namesUnmarked: Bool {
        #if HERMES_PUSH
        PushCenter.shared.namesUnmarked(gatewayID)
        #else
        false
        #endif
    }

    /// Listed chats Hermes never marked (`last_read_at` empty), which it reads as read and so does
    /// this list (`update`): the extension and the plugin don't count their news either, until a
    /// read marks them (`docs/notifications.md` §2 Badge). Bot Chats count by the Bot's read point.
    private func unmarkedSessions() -> [HermesSession] {
        guard let workspace, hasGatewayMarks else { return [] }
        let botChats = workspace.roster?.botChats ?? [:]
        return workspace.sessions.filter { session in
            (readMark(for: session.stableID) ?? .untracked) == .untracked
                && botChats[session.id] == nil && botChats[session.stableID] == nil
        }
    }

    /// The listed chats Hermes never marked, as the plugin names them (`presence away` with `unmarked`).
    func unmarkedChats() -> AppPushClient.ChatLists {
        AppPushClient.ChatLists(chats: Set(unmarkedSessions().map(\.id)).sorted(), rooms: [])
    }

    /// The chats the app lists, as the plugin names them (`presence away` with `listed`): a reply
    /// for anything else, or for a hidden Bot, never counts in its badge either.
    func listedChats() -> AppPushClient.ChatLists {
        guard let workspace else { return AppPushClient.ChatLists() }
        let hidden = hiddenBots
        let botChats = workspace.roster?.botChats ?? [:]
        let hiddenChats = Set(botChats.filter { hidden.contains($0.value) }.keys)
        return AppPushClient.ChatLists(
            chats: Array(Set(workspace.sessions.map(\.id)).subtracting(hiddenChats)
                .union(BadgeScope.countedBotChats(botChats, hiddenBots: hidden).keys)).sorted(),
            rooms: (workspace.roster?.groupRooms.rooms.map(\.id) ?? []).sorted()
        )
    }

    /// What the badge counts and what's muted, as the plugin names them (`presence away`), so it
    /// keeps the badge right while the app is away.
    func badgeLists() -> (unread: AppPushClient.ChatLists, muted: AppPushClient.ChatLists) {
        // The plugin counts ids: one per chat, the one its notices carry (the newest session).
        let counted = badgeChats()
        let unread = AppPushClient.ChatLists(
            chats: counted.compactMap { chat -> String? in
                guard chat.room == nil else { return nil }
                if chat.key.hasPrefix("bot:") {
                    return workspace?.roster?.bot(named: String(chat.key.dropFirst(4)))?.canonicalSession?.resolvedID ?? chat.ids.first
                }
                return workspace?.session(forKey: chat.key)?.id ?? chat.key
            },
            rooms: counted.compactMap(\.room)
        )
        var muted = AppPushClient.ChatLists()
        let botChats = workspace?.roster?.botChats ?? [:]
        for key in mutes.ends.keys.sorted() where mutes.isMuted(key) {
            if key.hasPrefix("bot:") {
                let name = String(key.dropFirst(4))
                muted.chats += botChats.filter { $0.value == name }.keys.sorted()
            } else if key.hasPrefix("group:") {
                muted.rooms.append(String(key.dropFirst(6)))
            } else {
                muted.chats += Array(Set([key, workspace?.session(forKey: key)?.id].compactMap { $0 })).sorted()
            }
        }
        return (unread, muted)
    }

    /// Read here (opened, or Mark as Read): the gateway tells the person's other devices, whose
    /// notifications for it go (`docs/notifications.md` §2 Reading).
    func didRead(chats: [String] = [], rooms: [String] = []) {
        #if HERMES_PUSH
        guard let workspace else { return }
        PushCenter.shared.didRead(chats: chats, rooms: rooms, in: workspace)
        #endif
    }

    // MARK: Read and unread

    /// Read now, on every device: the chat was opened (or its newest message was on screen for a
    /// second), or Mark as Read.
    func markRead(_ key: String) {
        if key.hasPrefix("bot:") {
            workspace?.roster?.markRead(String(key.dropFirst(4)))
            return
        }
        if key.hasPrefix("group:") {
            workspace?.roster?.groupRooms.markRead(String(key.dropFirst(6)))
            update()
            return
        }
        guard let session = workspace?.session(forKey: key), let active = session.lastActive else { return }
        let wasUnread = readMark(for: key).map { $0 == .markedUnread || $0.isUnread(lastActive: active) } ?? true
        cache.watermarks[key] = active.timeIntervalSince1970
        if hasGatewayMarks { pending[key] = (.readUntil(active), .now) }
        scheduleSave()
        update()
        guard wasUnread else { return }
        didRead(chats: [session.id, key])
        Task { await self.setUnread(false, session: session) }
    }

    /// Mark as Unread (`docs/inbox.md` §4): the dot on every device, until opened.
    func markUnread(_ key: String) {
        if key.hasPrefix("bot:") {
            let name = String(key.dropFirst(4))
            Task { try? await self.workspace?.roster?.markUnread(name) }
            return
        }
        guard let session = workspace?.session(forKey: key) else { return }
        if hasGatewayMarks {
            pending[key] = (.markedUnread, .now)
        } else {
            cache.watermarks[key] = 0
            scheduleSave()
        }
        update()
        Task { await self.setUnread(true, session: session) }
    }

    /// Mark All as Read: every badge clears at once; the gateway hears of them 4 calls at a time.
    func markAllRead(_ keys: [String]) async {
        let unread = keys.filter { badge(for: $0).isUnread }
        var sessions: [HermesSession] = []
        for key in unread {
            if key.hasPrefix("bot:") || key.hasPrefix("group:") {
                markRead(key)
                continue
            }
            guard let session = workspace?.session(forKey: key), let active = session.lastActive else { continue }
            cache.watermarks[key] = active.timeIntervalSince1970
            if hasGatewayMarks { pending[key] = (.readUntil(active), .now) }
            sending[key, default: 0] += 1
            sessions.append(session)
        }
        update()
        scheduleSave()
        didRead(chats: sessions.flatMap { Array(Set([$0.id, $0.stableID])) })
        for start in stride(from: 0, to: sessions.count, by: 4) {
            await withTaskGroup(of: Void.self) { group in
                for session in sessions[start..<min(start + 4, sessions.count)] {
                    group.addTask { await self.setUnread(false, session: session, counted: true) }
                }
            }
        }
    }

    /// The gateway's API server takes `unread` (Hermes 0.22); an older one refuses the field and
    /// the dashboard takes it instead.
    /// - Parameter counted: `markAllRead` has counted it in `sending` already.
    private func setUnread(_ unread: Bool, session: HermesSession, counted: Bool = false) async {
        let key = session.stableID
        if !counted { sending[key, default: 0] += 1 }
        defer {
            sending[key, default: 1] -= 1
            if sending[key] == 0 { sending[key] = nil }
            // The 10 s a mark holds start now.
            if pending[key] != nil { pending[key]?.at = .now }
        }
        guard let workspace else { return }
        let through = session.lastActive ?? .now
        do {
            guard let client = workspace.client else { return }
            _ = try await client.setSessionFlags(id: session.id, unread: unread)
            if !unread { readSent(key, through: through) }
        } catch HermesError.server(status: 400, _, _) {
            guard let backend = workspace.roster?.boardClient else { return }
            do {
                if unread {
                    try await backend.markUnread(storedSessionID: session.id, profile: workspace.bot.profileName)
                } else {
                    try await backend.markRead(storedSessionID: session.id, profile: workspace.bot.profileName)
                    readSent(key, through: through)
                }
            } catch {
                ConnectionLog.logger.notice("inbox: couldn't share a read mark: \(String(describing: type(of: error)), privacy: .public)")
                if !unread { readFailed(key, through: through) }
            }
        } catch {
            ConnectionLog.logger.notice("inbox: couldn't share a read mark: \(String(describing: type(of: error)), privacy: .public)")
            if !unread { readFailed(key, through: through) }
        }
    }

    // MARK: Hermes' marks

    /// The chat list or the Bots' sessions moved (`sessions.changed`), or the app came to the
    /// front: marks may have moved on another device.
    func sessionsMayHaveMoved() {
        recheck.mayHaveMoved()
    }

    /// Bot Mode came online: Hermes' marks, the list kept fresh while the app runs, and reads that
    /// waited for the gateway.
    func connected() {
        fetchMarks(now: true)
        startPolling()
        flushReads()
        // And the list, against which the reads the push plugin hasn't heard yet are judged
        // (`PushCenter.chatListFetched`), so the other devices' badges drop.
        refreshListSoon()
    }

    // MARK: The read outbox

    /// A read reached the gateway.
    func readSent(_ key: String, through: Date) {
        outbox.sent(key, through: through)
        saveOutbox()
    }

    /// A read didn't reach the gateway: it waits, like a message in the send outbox.
    func readFailed(_ key: String, through: Date) {
        outbox.queue(key, through: through)
        outbox.failed(key)
        saveOutbox()
        scheduleOutboxFlush()
    }

    /// Sends the reads whose turn it is, unless their chat has news since (Hermes would stamp that
    /// read too, unseen).
    func flushReads() {
        guard let workspace else { return }
        for entry in outbox.due() {
            // Counted as a try now, so the next pass doesn't send it twice; landing clears it.
            outbox.failed(entry.key)
            if entry.key.hasPrefix("bot:") {
                if workspace.roster?.resendRead(String(entry.key.dropFirst(4)), through: entry.through) != true {
                    outbox.drop(entry.key)
                }
            } else if let session = workspace.session(forKey: entry.key), ReadOutbox.isCurrent(entry, lastActive: session.lastActive) {
                Task { await self.setUnread(false, session: session) }
            } else {
                outbox.drop(entry.key)
            }
        }
        saveOutbox()
        scheduleOutboxFlush()
    }

    private func scheduleOutboxFlush() {
        outboxFlush?.cancel()
        guard let next = outbox.entries.values.map(\.nextTry).min() else { return }
        outboxFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            self.flushReads()
        }
    }

    private func saveOutbox() {
        if outbox.isEmpty {
            UserDefaults.standard.removeObject(forKey: outboxKey)
        } else if let data = try? JSONEncoder().encode(outbox) {
            UserDefaults.standard.set(data, forKey: outboxKey)
        }
    }

    func disconnected() {
        pollTask?.cancel()
        pollTask = nil
        #if HERMES_PUSH
        if let workspace { PushCenter.shared.gatewayWentAway(workspace) }
        #endif
    }

    func tearDown() {
        disconnected()
        recheck.cancel()
        countRetry?.cancel()
        muteTimer?.cancel()
        listRefresh?.cancel()
        saveTask?.cancel()
        save()
    }

    /// Between change events, unread chats are asked about with the Bots' backoff (every 60 s at
    /// most while the Mac app is behind other apps).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Double = AppPresence.isInBack ? 60 : 15
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
                guard let self, !Task.isCancelled else { return }
                if self.badges.keys.contains(where: { !$0.hasPrefix("bot:") && !$0.hasPrefix("group:") }) {
                    self.fetchMarks(now: false)
                }
            }
        }
    }

    /// Hermes' marks for the newest chats (the dashboard's rows), and the chat list itself when
    /// something moved.
    private func fetchMarks(now: Bool) {
        guard let workspace, let backend = workspace.roster?.boardClient, recheck.isDue("chats", now: now) else { return }
        if now { refreshListSoon() }
        Task { [weak self] in
            defer { self?.recheck.answered("chats") }
            guard let rows = try? await backend.recentSessions(limit: 100, profile: workspace.bot.profileName) else { return }
            self?.adopt(rows)
        }
    }

    /// Hermes' marks now, awaited: an app woken in the background (a `sync` push, an app refresh)
    /// counts from them, never from the marks it left with, or a chat read on another device while it
    /// slept would go back on the icon (`docs/notifications.md` §2 Badge).
    func catchUpMarks() async {
        guard let workspace, let backend = workspace.roster?.boardClient,
              let rows = try? await backend.recentSessions(limit: 100, profile: workspace.bot.profileName) else { return }
        adopt(rows)
    }

    private func adopt(_ rows: [HermesSession]) {
        var marks: [String: ReadMark] = [:]
        for row in rows {
            marks[row.stableID] = row.readMark ?? .untracked
        }
        // A dashboard without read marks (older Hermes): the device keeps them.
        guard rows.contains(where: { $0.readMark != nil }) else { return }
        // A mark this device just set holds until Hermes' agrees, or for 10 s.
        for (key, edit) in pending {
            let agrees: Bool = switch (edit.mark, marks[key]) {
            case (.markedUnread, .markedUnread?): true
            case (.readUntil(let mine), .readUntil(let theirs)?): theirs.timeIntervalSince(mine) > -1
            default: false
            }
            if agrees || (sending[key] == nil && Date.now.timeIntervalSince(edit.at) > 10) { pending[key] = nil }
        }
        hasGatewayMarks = true
        recheck.keep(badges.isEmpty ? [] : ["chats"])
        if marks != cache.marks {
            cache.marks = marks
            scheduleSave()
        }
        update()
    }

    /// The chat list again after a change event: rows move to the top as they get activity. At
    /// most every 3 s.
    private func refreshListSoon() {
        guard listRefresh == nil else { return }
        let wait = max(0, 3 - Date.now.timeIntervalSince(listRefreshedAt))
        listRefresh = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.listRefreshedAt = .now
            await self.workspace?.refreshSessions()
            self.listRefresh = nil
        }
    }

    // MARK: Mute

    func mute(_ key: String, for duration: MuteList.Duration) {
        mutes.mute(key, for: duration)
        cache.mutes = mutes
        scheduleSave()
        scheduleMuteEnd()
        sharePushMutes()
    }

    func unmute(_ key: String) {
        mutes.unmute(key)
        cache.mutes = mutes
        scheduleSave()
        sharePushMutes()
    }

    /// The Notification Service reads the mutes (it delivers muted chats quietly). A notice names
    /// a chat by its live session id, which compression moves on from the key kept here.
    private func sharePushMutes() {
        var ends = mutes.ends
        for (key, end) in mutes.ends {
            if let session = workspace?.session(forKey: key), session.id != key { ends[session.id] = end }
        }
        PushShared.current.setMutes(ends, gateway: gatewayID)
        #if HERMES_PUSH
        // A muted chat leaves the app icon badge, an unmuted unread one comes back.
        PushCenter.shared.unreadChanged(badgeChats(), countable: countableChats(), gateway: gatewayID)
        #endif
    }

    /// Redraws when the next mute ends.
    private func scheduleMuteEnd() {
        muteTimer?.cancel()
        guard let end = mutes.nextEnd() else { return }
        muteTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow + 0.5)))
            guard let self, !Task.isCancelled else { return }
            var mutes = self.mutes
            if mutes.prune() {
                self.mutes = mutes
                self.cache.mutes = mutes
                self.scheduleSave()
                self.sharePushMutes()
            }
            self.scheduleMuteEnd()
        }
    }

    // MARK: Opening a chat

    /// A chat is about to open: how far it was read, if there's something new in it. Bots are
    /// marked read as they open, so this comes first.
    func noteOpening(_ key: String) {
        openings[key] = nil
        if key.hasPrefix("bot:") {
            let name = String(key.dropFirst(4))
            guard let roster = workspace?.roster, roster.unread.contains(name), !roster.markedUnread.contains(name) else { return }
            openings[key] = Opening(since: roster.readPoint(name), seenThrough: cache.seen[key])
            return
        }
        guard let session = workspace?.session(forKey: key), let mark = readMark(for: key) else { return }
        switch mark {
        case .readUntil(let read) where mark.isUnread(lastActive: session.lastActive):
            openings[key] = Opening(since: read, seenThrough: cache.seen[key])
        case .markedUnread where cache.seen[key] != nil:
            openings[key] = Opening(since: nil, seenThrough: cache.seen[key])
        default:
            break
        }
    }

    /// The opening noted for a chat, once: the transcript places its New Messages line by it.
    func takeOpening(_ key: String) -> Opening? {
        defer { openings[key] = nil }
        return openings[key]
    }

    /// The opening for a chat. The app opened straight into it before Hermes' marks (Bot Mode)
    /// or the chat list had ever come in: wait for them, up to 2.5 s.
    func opening(for key: String) async -> Opening? {
        if let noted = takeOpening(key) { return noted }
        guard !key.hasPrefix("bot:"), let workspace else { return nil }
        var waited = 0
        while waited < 2500, !Task.isCancelled,
              (workspace.bot.backend != nil && !hasGatewayMarks) || workspace.sessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
        }
        noteOpening(key)
        return takeOpening(key)
    }

    // MARK: Where a chat was left

    /// The last row shown on this device (the New Messages line resumes after it).
    func seenThrough(_ key: String) -> String? {
        cache.seen[key]
    }

    func setSeenThrough(_ key: String, rowID: String) {
        guard cache.seen[key] != rowID else { return }
        cache.seen[key] = rowID
        scheduleSave()
    }

    /// The row at the top of a chat left scrolled up; nil at the bottom.
    func scrollRow(_ key: String) -> String? {
        cache.scroll[key]
    }

    func setScrollRow(_ key: String, rowID: String?) {
        guard cache.scroll[key] != rowID else { return }
        cache.scroll[key] = rowID
        scheduleSave()
    }

    // MARK: Saving

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        // Only chats still in the list (and every Bot, group and mute) are kept.
        if let workspace, !workspace.sessions.isEmpty {
            let keys = Set(workspace.sessions.map(\.stableID))
            func keep(_ key: String) -> Bool { keys.contains(key) || key.contains(":") }
            cache.counts = cache.counts.filter { keep($0.key) }
            cache.marks = cache.marks.filter { keep($0.key) }
            cache.watermarks = cache.watermarks.filter { keep($0.key) }
            cache.seen = cache.seen.filter { keep($0.key) }
            cache.scroll = cache.scroll.filter { keep($0.key) }
        }
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey(gatewayID))
        }
    }
}
