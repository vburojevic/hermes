import Foundation
import HermesKit
import HermesPush
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The gateway's hosted group chats (`groups.*`). Rooms run server-side; there are no room
/// events on the socket, so lists and chats are read by polling.
@MainActor
@Observable
final class GroupRooms {
    private(set) var rooms: [GroupRoom] = []
    /// The gateway runs rooms (`groups.capabilities.driver`).
    private(set) var isAvailable = false
    /// `dashboard.turn_isolation` is on: Hermes refuses members' turns (4121) and requeues them
    /// for ever, so rooms never answer (`docs/setup.md` §4.12).
    private(set) var turnIsolation = false
    private(set) var isLoaded = false
    /// Members' messages since the person last looked, by room (`docs/inbox.md` §1). Hermes keeps
    /// no read mark for rooms, so this device does: the last event seen in each.
    private(set) var unreadCounts: [String: Int] = [:] {
        didSet { if unreadCounts != oldValue { roster?.workspace?.unread.update() } }
    }
    /// The first unseen message in a room that mentions the person: who, and where.
    private(set) var mentions: [String: (memberID: String, seq: Int)] = [:]
    /// Open chats, by room id.
    @ObservationIgnored private var chats: [String: GroupChatModel] = [:]
    @ObservationIgnored private weak var roster: BotRoster?
    @ObservationIgnored private var seenSeq: [String: Int]
    @ObservationIgnored private var countedSeq: [String: Int] = [:]
    @ObservationIgnored private let seenKey: String
    /// When each room was last read here (unix seconds), for its notifications.
    @ObservationIgnored private var readTimes: [String: Double]
    @ObservationIgnored private let readKey: String

    init(roster: BotRoster) {
        self.roster = roster
        seenKey = "groupSeen.\(roster.botID.uuidString)"
        seenSeq = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Int] ?? [:]
        readKey = "groupReadAt.\(roster.botID.uuidString)"
        readTimes = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Double] ?? [:]
    }

    func refresh() async {
        guard let roster, roster.isConnected else { return }
        if !isLoaded {
            let capabilities = try? await roster.request("groups.capabilities")
            isAvailable = capabilities?["driver"]?.boolValue ?? false
            await checkTurnIsolation()
        }
        // A gateway without group chats isn't asked for them on every roster poll.
        guard isAvailable || !isLoaded else { return }
        guard let result = try? await roster.request("groups.list", ["limit": .number(100)]),
              case .array(let rows)? = result["rooms"] else {
            isLoaded = true
            return
        }
        rooms = rows.compactMap(GroupRoom.parse).filter { $0.disbandedAt == nil }
        isLoaded = true
        await countUnread()
    }

    /// Bot Mode came back: ask again whether rooms run and turn isolation is on, so a room
    /// service that started late (or stopped) shows (`docs/setup.md` §4.12).
    func connected() {
        isLoaded = false
    }

    /// Reads `dashboard.turn_isolation` (`GET /api/config`): on first load, and as a room opens.
    func checkTurnIsolation() async {
        guard let roster, roster.isConnected,
              let config = try? await roster.backendClient.config(profile: nil) else { return }
        let on = config["dashboard"]?["turn_isolation"]?.boolValue ?? false
        if on != turnIsolation { turnIsolation = on }
    }

    /// Turn Off Turn Isolation, after the person confirmed (`PUT /api/config`, read by Hermes on
    /// each call, so rooms answer again without a restart).
    func turnOffTurnIsolation() async throws {
        guard let roster else { return }
        try await roster.backendClient.updateConfig(.object(["dashboard": .object(["turn_isolation": .bool(false)])]), profile: nil)
        await checkTurnIsolation()
    }

    /// Rooms that moved since they were last seen: their members' messages counted again.
    private func countUnread() async {
        guard let roster else { return }
        var seededAny = false
        for room in rooms {
            guard let latest = room.latestSeq else { continue }
            guard let seen = seenSeq[room.id] else {
                // First sight: what's there is read.
                seenSeq[room.id] = latest
                seededAny = true
                continue
            }
            if roster.workspace?.unread.openKey == UnreadStore.groupKey(room.id) {
                markRead(room.id)
                continue
            }
            guard latest > seen, countedSeq[room.id] != latest else { continue }
            countedSeq[room.id] = latest
            guard let page = try? await roster.request("groups.log", ["room_id": .string(room.id), "since_seq": .number(0), "limit": .number(200)]),
                  case .array(let rows)? = page["events"] else { continue }
            let found = RoomTranscript.unread(rows.compactMap(RoomEvent.parse), after: seen, names: PushShared.current.preferences.mentionNames)
            unreadCounts[room.id] = found.count
            mentions[room.id] = found.mention
        }
        let ids = Set(rooms.map(\.id))
        unreadCounts = unreadCounts.filter { ids.contains($0.key) }
        if seededAny { UserDefaults.standard.set(seenSeq, forKey: seenKey) }
    }

    /// Where a room was read up to on this device, for its New Messages line; taken as it opens.
    func seenSeq(_ id: String) -> Int? {
        seenSeq[id]
    }

    /// The room was read here: everything up to its latest event.
    func markRead(_ id: String) {
        let latest = max(room(id)?.latestSeq ?? 0, chats[id]?.latestSeq ?? 0)
        let hadNews = latest > (seenSeq[id] ?? 0) || unreadCounts[id] != nil
        if latest > (seenSeq[id] ?? 0) {
            seenSeq[id] = latest
            UserDefaults.standard.set(seenSeq, forKey: seenKey)
        }
        if hadNews {
            readTimes[id] = Date.now.timeIntervalSince1970
            UserDefaults.standard.set(readTimes, forKey: readKey)
        }
        if unreadCounts[id] != nil { unreadCounts[id] = nil }
        if mentions[id] != nil { mentions[id] = nil }
        // Rooms keep no read mark on the gateway: the plugin tells the other devices instead.
        if hadNews { roster?.workspace?.unread.didRead(rooms: [id]) }
    }

    /// Rooms read on another device by then (the push plugin passes reads on: rooms have no read
    /// mark on the gateway, `docs/notifications.md` §2 Reading): read here too, unless they moved since.
    func readElsewhere(_ reads: [String: Date]) {
        var changed = false
        for (id, at) in reads where unreadCounts[id] != nil || mentions[id] != nil {
            guard let room = room(id), (room.updatedAt ?? .distantPast) <= at.addingTimeInterval(1) else { continue }
            seenSeq[id] = max(seenSeq[id] ?? 0, room.latestSeq ?? 0, chats[id]?.latestSeq ?? 0)
            readTimes[id] = max(readTimes[id] ?? 0, at.timeIntervalSince1970)
            unreadCounts[id] = nil
            mentions[id] = nil
            changed = true
        }
        guard changed else { return }
        UserDefaults.standard.set(seenSeq, forKey: seenKey)
        UserDefaults.standard.set(readTimes, forKey: readKey)
    }

    /// When the room was last read here: its notifications from before can go.
    func readAt(_ id: String) -> Date? {
        readTimes[id].map { Date(timeIntervalSince1970: $0) }
    }

    func room(_ id: String) -> GroupRoom? {
        rooms.first { $0.id == id }
    }

    func chat(for id: String) -> GroupChatModel? {
        guard let roster, let room = room(id) else { return nil }
        if let chat = chats[id] { return chat }
        let chat = GroupChatModel(room: room, roster: roster, rooms: self)
        chats[id] = chat
        return chat
    }

    /// New Group Chat: two to six Bots.
    func create(name: String, bots: [BotProfile]) async throws -> GroupRoom {
        guard let roster else { throw GatewaySocket.Failure.notConnected }
        let members = bots.map { GroupRoom.Member(memberID: $0.name, profile: $0.name, handle: $0.mentionTag, displayName: $0.title) }
        let result = try await roster.request("groups.create", [
            "room_id": .string(GroupRoom.newID(for: name)),
            "name": .string(name),
            "members": .array(members.map(\.json)),
        ], timeout: .seconds(30))
        guard let room = result["room"].flatMap(GroupRoom.parse) else { throw HermesError.invalidResponse("groups.create") }
        rooms.insert(room, at: 0)
        return room
    }

    func rename(_ room: GroupRoom, to name: String) async throws {
        guard let roster else { return }
        _ = try await roster.request("groups.rename", ["room_id": .string(room.id), "event_id": .string(UUID().uuidString), "name": .string(name)])
        if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index].name = name }
        chats[room.id]?.room.name = name
    }

    func disband(_ room: GroupRoom) async throws {
        guard let roster else { return }
        _ = try await roster.request("groups.disband", ["room_id": .string(room.id), "cancel_id": .string(UUID().uuidString)], timeout: .seconds(30))
        rooms.removeAll { $0.id == room.id }
        chats[room.id]?.close()
        chats[room.id] = nil
    }

    /// A chat saw new activity: keep the list's order and preview current.
    func touched(_ room: GroupRoom) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[index] = room
        }
    }

    /// Who's at work in a room open this launch (who goes in front on its row).
    func workingMembers(_ id: String) -> [String] {
        guard let chat = chats[id], chat.isWorking else { return [] }
        return chat.activeMemberID.map { [$0] } ?? []
    }

    /// The latest line, when it was written and whether the room waits on the person, for the
    /// roster row.
    func summary(for id: String) -> (preview: String?, at: Date?, needsYou: Bool) {
        guard let chat = chats[id] else { return (nil, nil, false) }
        let latest = chat.latestMessage
        return (latest?.text, latest?.at, chat.pendingApproval != nil)
    }
}

/// One open group chat: its log, who's done what this round, and what's waiting on the person.
@MainActor
@Observable
final class GroupChatModel {
    struct PendingApproval: Equatable {
        var memberID: String
        var taskID: String
        var executionGeneration: JSONValue
        var requestID: String
        var request: ApprovalRequest
    }

    var room: GroupRoom
    private(set) var events: [RoomEvent] = []
    private(set) var items: [RoomItem] = []
    private(set) var isWorking = false
    private(set) var pendingApproval: PendingApproval?
    private(set) var retryTask: String?
    private(set) var error: String?
    var draft = "" {
        didSet {
            // A pill whose text was edited away goes with it.
            if !draftReferences.isEmpty {
                let valid = MessageParts.valid(draftReferences, in: draft)
                if valid != draftReferences { draftReferences = valid }
            }
        }
    }
    /// Bots picked into the draft, drawn as pills (`composerReferences`); sent as `@handle`.
    var draftReferences: [MessageReference] = []

    /// Your messages on their way to the room: shown at once, sent and sent again under the same
    /// `event_id` until Hermes takes them (it appends a person's message once per id), and gone
    /// when the room's log has them (`docs/bots-groups-skills.md` §2).
    struct PendingPost: Identifiable, Equatable {
        /// The `event_id` it goes with.
        let id: String
        let text: String
        /// Not taken after a moment: the row says it's waiting for the Mac.
        var isWaiting = false
        /// Written to the socket at least once: Hermes may have it, so it can't be taken back.
        var isWritten = false
        /// Hermes took it (`groups.send` answered); the row stays until the log has it.
        var isTaken = false
        /// Its event in the room's log, when Hermes said.
        var seq: Int?
    }
    private(set) var pendingPosts: [PendingPost] = [] {
        didSet {
            // Kept on the device until Hermes takes them (`KeptPost`): a relaunch sends them again
            // under the same id.
            let kept = pendingPosts.filter { !$0.isTaken }.map { KeptPost(eventID: $0.id, text: $0.text) }
            if kept != oldValue.filter({ !$0.isTaken }).map({ KeptPost(eventID: $0.id, text: $0.text) }) {
                GroupPostStore.save(kept, room: room.id)
            }
        }
    }
    @ObservationIgnored private var postTasks: [String: Task<Void, Never>] = [:]
    /// Log rows that took over from a pending row keep its identity, so the row doesn't go and
    /// come back as the log catches up: `e<seq>` → `post-<event id>`.
    @ObservationIgnored private var rowAliases: [String: String] = [:]

    /// The room's rows, then your messages still on their way.
    var shownItems: [RoomItem] {
        let logged = rowAliases.isEmpty ? items : items.map { item in
            guard case .user(let id, let text, let date) = item, let alias = rowAliases[id] else { return item }
            return RoomItem.user(id: alias, text: text, date: date)
        }
        return logged + pendingPosts.map { RoomItem.user(id: Self.pendingRowID($0.id), text: $0.text, date: nil) }
    }

    static func pendingRowID(_ postID: String) -> String { "post-\(postID)" }

    /// Words only: Hermes may store the message's spacing differently.
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func pendingPost(rowID: String) -> PendingPost? {
        pendingPosts.first { Self.pendingRowID($0.id) == rowID }
    }

    @ObservationIgnored private weak var roster: BotRoster?
    @ObservationIgnored private weak var rooms: GroupRooms?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastSeq = 0
    /// The newest event read so far.
    var latestSeq: Int { lastSeq }

    init(room: GroupRoom, roster: BotRoster, rooms: GroupRooms) {
        self.room = room
        self.roster = roster
        self.rooms = rooms
        // Messages that were on their way when the app last ran: they go again, under their ids.
        // Each may have been written to the socket already, so none can be taken back.
        for kept in GroupPostStore.load(room: room.id) {
            let post = PendingPost(id: kept.eventID, text: kept.text, isWaiting: true, isWritten: true)
            pendingPosts.append(post)
            isWorking = true
            postTasks[post.id] = Task { [weak self] in
                await self?.deliver(post)
                self?.postTasks[post.id] = nil
            }
        }
    }

    var memberStates: [String: RoomTranscript.MemberState] { RoomTranscript.memberStates(events) }
    /// The member whose turn is running (`turn.started` in the room's log).
    var activeMemberID: String? { RoomTranscript.activeMember(events) }
    /// The members thinking before their first words (`botThinkingLine`).
    var thinkingMemberIDs: [String] { RoomTranscript.thinkingMembers(events) }
    /// The latest member message that hands work to another member by `@handle`.
    var lastHandOff: (from: String, to: String, seq: Int)? {
        RoomTranscript.lastHandOff(events, handles: Dictionary(room.members.map { ($0.memberID, $0.handle) }, uniquingKeysWith: { a, _ in a }))
    }
    var currentRound: Int { RoomTranscript.currentRound(events) }

    /// The newest message, a member's or the person's: the row's line and its time (`RowTime`).
    var latestMessage: (text: String, at: Date?)? {
        for item in items.reversed() {
            switch item {
            case .member(_, let memberID, let text, let date): return ("\(member(memberID)?.displayName ?? memberID): \(text)", date)
            case .user(_, let text, let date): return (text, date)
            default: continue
            }
        }
        return nil
    }

    func member(_ id: String) -> GroupRoom.Member? {
        room.members.first { $0.memberID == id }
    }

    // MARK: Polling

    /// Reads the log from where it left off: quickly while Bots are replying, slowly otherwise.
    func open() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                // Not in front (a Mac window behind others, iOS on its way out): every 15 s.
                let quick = self.isWorking || self.pendingApproval != nil
                try? await Task.sleep(for: !Self.isInFront ? .seconds(15) : quick ? .milliseconds(1200) : .seconds(5))
            }
        }
    }

    func close() {
        poller?.cancel()
        poller = nil
    }

    private static var isInFront: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApp.isActive
        #endif
    }

    func poll() async {
        // Paused (the app away, or just back): no poll brings the socket back; the next one after
        // it's back catches up.
        guard let roster, roster.isConnected, !roster.isPaused else { return }
        do {
            var hasMore = true
            var fresh: [RoomEvent] = []
            while hasMore {
                let page = try await roster.request("groups.log", ["room_id": .string(room.id), "since_seq": .number(Double(lastSeq)), "limit": .number(200)])
                if case .array(let rows)? = page["events"] {
                    fresh += rows.compactMap(RoomEvent.parse)
                }
                if let cursor = page["cursor"]?.doubleValue { lastSeq = max(lastSeq, Int(cursor)) }
                if let last = fresh.last?.seq { lastSeq = max(lastSeq, last) }
                hasMore = page["has_more"]?.boolValue ?? false
            }
            if !fresh.isEmpty {
                events += fresh
                items = RoomTranscript.build(events)
                // Yours, in the log now: no longer on their way. By the event Hermes said it was,
                // else by its words.
                for event in fresh where event.kind == "message.user" {
                    let text = Self.words(event.payload["text"]?.stringValue ?? "")
                    let index = pendingPosts.firstIndex { $0.seq == event.seq }
                        ?? pendingPosts.firstIndex { $0.seq == nil && Self.words($0.text) == text }
                    if let index {
                        rowAliases["e\(event.seq)"] = Self.pendingRowID(pendingPosts[index].id)
                        pendingPosts.remove(at: index)
                    }
                }
                if roster.workspace?.widgets.isAvailable == true {
                    widgetFacts = WidgetChatFacts.build(room: items)
                    await refreshAnsweredWidgets()
                }
                if let name = fresh.last(where: { $0.kind == "room.renamed" })?.payload["name"]?.stringValue { room.name = name }
                room.updatedAt = fresh.last?.createdAt ?? room.updatedAt
                rooms?.touched(room)
                // Read as it comes in, while it's on screen.
                if Self.isInFront, roster.workspace?.unread.openKey == UnreadStore.groupKey(room.id) { rooms?.markRead(room.id) }
            }
            let state = try await roster.request("groups.state", ["room_id": .string(room.id)])
            readDriverStatus(state["driver_status"])
            error = nil
        } catch {
            self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
        }
    }

    private func readDriverStatus(_ status: JSONValue?) {
        isWorking = (status?["working"]?.boolValue ?? false) || !RoomTranscript.isSettled(events) || pendingPosts.contains { !$0.isTaken }
        var approval: PendingApproval?
        var retry: String?
        if case .array(let actions)? = status?["pending_actions"] {
            for action in actions {
                switch action["kind"]?.stringValue {
                case "approval":
                    guard let taskID = action["task_id"]?.stringValue, let requestID = action["request_id"]?.stringValue,
                          let memberID = action["member_id"]?.stringValue, let details = action["approval"],
                          let data = try? JSONEncoder().encode(details),
                          var request = try? JSONDecoder().decode(ApprovalRequest.self, from: data) else { continue }
                    // Rooms take once or deny.
                    request.choices = [.once, .deny]
                    approval = PendingApproval(memberID: memberID, taskID: taskID, executionGeneration: action["execution_generation"] ?? .number(0), requestID: requestID, request: request)
                case "retry":
                    retry = action["task_id"]?.stringValue
                default:
                    break
                }
            }
        }
        if approval != pendingApproval { pendingApproval = approval }
        if retry != retryTask { retryTask = retry }
    }

    // MARK: Widgets (`docs/widgets.md` §7)

    /// What the room's rows say about its widgets.
    private(set) var widgetFacts = WidgetChatFacts()
    @ObservationIgnored private var widgetHostStorage: WidgetHost?

    /// The cards' host, on gateways with the widgets plugin.
    var widgetHost: WidgetHost? {
        guard let store = roster?.workspace?.widgets, store.isAvailable else { return nil }
        if let widgetHostStorage { return widgetHostStorage }
        let host = WidgetHost(room: self, store: store)
        widgetHostStorage = host
        return host
    }

    /// Tells the plugin this room is the app's, once a run: its members' replies then carry their
    /// widgets as inline blocks (the app never sees their tool rows).
    func markForWidgets() async {
        let key = "room:" + room.id
        guard let roster, roster.isConnected, let store = roster.workspace?.widgets, store.isAvailable, store.needsMark(key) else { return }
        let client = AppWidgetsClient { method, params in try await roster.request(method, params) }
        if (try? await client.markRoom(room.id)) != nil { store.noteMarked(key) }
    }

    /// A room shows no tool rows, so an update to a widget the person answered is read from the
    /// plugin's store when the room moves on.
    private func refreshAnsweredWidgets() async {
        guard let roster, let store = roster.workspace?.widgets else { return }
        let client = AppWidgetsClient { method, params in try await roster.request(method, params) }
        for (id, answers) in widgetFacts.answers {
            guard let answer = answers.last, let current = store.payload(id), current.rev <= answer.rev,
                  current.envelope.resolution == nil else { continue }
            if let json = try? await client.widget(id) { store.ingest(json) }
        }
    }

    var canSendWidgetAnswer: Bool { roster?.isConnected == true }

    func sendWidgetAnswer(_ answer: WidgetAnswer) {
        roster?.workspace?.widgets.noteSent(answer, queued: false)
        sendWidgetText(answer.message)
    }

    /// An answer goes to the room as the person's message, like a typed one.
    func sendWidgetText(_ text: String) {
        guard let roster else { return }
        isWorking = true
        Task {
            do {
                _ = try await roster.request("groups.send", [
                    "room_id": .string(room.id),
                    "event_id": .string(UUID().uuidString),
                    "payload": .object(["text": .string(text), "thread_id": .string("main")]),
                ], timeout: .seconds(30))
                await poll()
            } catch {
                if let answer = WidgetAnswer.parse(text) { roster.workspace?.widgets.noteNotSent(answer) }
                self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
                isWorking = false
            }
        }
    }

    // MARK: Actions

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, roster != nil else { return }
        draftReferences = []
        draft = ""
        post(text)
    }

    /// A voice message's transcript (`docs/voice.md` §2): group chats carry text, so the words
    /// go and the recording stays on the device. What's typed in the field stays there.
    func sendSpoken(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        post(text)
    }

    /// Shows the message at once and sends it; a busy or away Mac only makes it wait.
    private func post(_ text: String) {
        guard roster != nil else { return }
        let post = PendingPost(id: UUID().uuidString, text: text)
        pendingPosts.append(post)
        error = nil
        isWorking = true
        postTasks[post.id] = Task { [weak self] in
            await self?.deliver(post)
            self?.postTasks[post.id] = nil
        }
    }

    /// Sends a pending post until Hermes takes it: over a socket that's away it waits for one, and
    /// a timeout or a dropped socket sends it again under the same `event_id`. Only a refusal
    /// gives it back to the field.
    private func deliver(_ post: PendingPost) async {
        let waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.update(post.id) { if !$0.isTaken { $0.isWaiting = true } }
        }
        defer { waiting.cancel() }
        var failures = 0
        // Waiting for a socket: the row says so now, not after the moment it gives a send.
        if roster?.isConnected != true { update(post.id) { $0.isWaiting = true } }
        var marked = false
        while !Task.isCancelled {
            guard let roster, await roster.untilConnected() else { return }
            if !marked {
                // Before the first send, so the members' replies carry their widgets.
                await markForWidgets()
                marked = true
            }
            update(post.id) { $0.isWritten = true }
            do {
                let sent = try await roster.request("groups.send", [
                    "room_id": .string(room.id),
                    "event_id": .string(post.id),
                    "payload": .object(["text": .string(post.text), "thread_id": .string("main")]),
                ], timeout: .seconds(30))
                update(post.id) { taken in
                    taken.isTaken = true
                    taken.isWaiting = false
                    taken.seq = sent["event"]?["seq"]?.truncatedIntValue
                }
                await poll()
                // Taken, and the log has moved past it without a match (Hermes stored the words
                // differently, or didn't say which event it was): the row goes.
                if let taken = pendingPosts.first(where: { $0.id == post.id }), taken.seq.map({ $0 <= lastSeq }) ?? true {
                    pendingPosts.removeAll { $0.id == post.id }
                }
                return
            } catch let refusal as GatewayRPCError {
                // Hermes said no (the room's gone, its Bots are unavailable): not lost, back in the field.
                giveBack(post, saying: refusal.message)
                return
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                try? await Task.sleep(for: .seconds(min(15, pow(2, Double(failures)))))
            }
        }
    }

    /// Don't Send: a message not written to the socket yet goes back to the field. One that was may
    /// be with Hermes already, so it isn't offered then: taking it back and sending it again would
    /// put it in the room twice.
    func takeBack(_ post: PendingPost) {
        guard let current = pendingPosts.first(where: { $0.id == post.id }), !current.isWritten else { return }
        postTasks.removeValue(forKey: post.id)?.cancel()
        giveBack(post, saying: nil)
    }

    private func update(_ id: String, _ change: (inout PendingPost) -> Void) {
        guard let index = pendingPosts.firstIndex(where: { $0.id == id }) else { return }
        change(&pendingPosts[index])
    }

    private func giveBack(_ post: PendingPost, saying message: String?) {
        guard pendingPosts.contains(where: { $0.id == post.id }) else { return }
        pendingPosts.removeAll { $0.id == post.id }
        draft = draft.isEmpty ? post.text : draft + " " + post.text
        if let message { error = message }
        if !pendingPosts.contains(where: { !$0.isTaken }), RoomTranscript.isSettled(events) { isWorking = false }
    }

    func stop() {
        guard let roster else { return }
        Task {
            _ = try? await roster.request("groups.stop", ["room_id": .string(room.id), "cancel_id": .string(UUID().uuidString)])
            await poll()
        }
    }

    /// Answers the approval the card showed (`requestID`); one that replaced it waits for its own.
    func respond(_ choice: ApprovalChoice, requestID: String) {
        guard let roster, let approval = pendingApproval, approval.requestID == requestID else { return }
        pendingApproval = nil
        Task {
            _ = try? await roster.request("groups.approve", [
                "room_id": .string(room.id),
                "member_id": .string(approval.memberID),
                "task_id": .string(approval.taskID),
                "execution_generation": approval.executionGeneration,
                "choice": .string(choice == .deny ? "deny" : "once"),
                "request_id": .string(approval.requestID),
            ])
            await poll()
        }
    }

    func retry() {
        guard let roster, let task = retryTask else { return }
        retryTask = nil
        Task {
            _ = try? await roster.request("groups.retry", ["room_id": .string(room.id), "task_id": .string(task)])
            await poll()
        }
    }
}

extension GroupChatModel: WidgetAnswerSender {}

/// Each group chat's messages on their way, on the device (Application Support), until Hermes
/// takes them (`KeptPost`).
enum GroupPostStore {
    private static func file(room: String) -> URL? {
        let safe = room.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appending(path: "GroupPosts", directoryHint: .isDirectory)
            .appending(path: "\(safe).json")
    }

    static func load(room: String) -> [KeptPost] {
        guard let file = file(room: room), let data = try? Data(contentsOf: file) else { return [] }
        return KeptPost.decode(data)
    }

    static func save(_ posts: [KeptPost], room: String) {
        guard let file = file(room: room) else { return }
        guard !posts.isEmpty, let data = KeptPost.encode(posts) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
