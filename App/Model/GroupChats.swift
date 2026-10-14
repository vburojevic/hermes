import Foundation
import HermesKit
import Observation

/// The gateway's hosted group chats (`groups.*`). Rooms run server-side; there are no room
/// events on the socket, so lists and chats are read by polling.
@MainActor
@Observable
final class GroupRooms {
    private(set) var rooms: [GroupRoom] = []
    /// The gateway runs rooms (`groups.capabilities.driver`).
    private(set) var isAvailable = false
    private(set) var isLoaded = false
    /// Open chats, by room id.
    @ObservationIgnored private var chats: [String: GroupChatModel] = [:]
    @ObservationIgnored private weak var roster: BotRoster?

    init(roster: BotRoster) {
        self.roster = roster
    }

    func refresh() async {
        guard let roster, roster.isConnected else { return }
        if !isLoaded {
            let capabilities = try? await roster.request("groups.capabilities")
            isAvailable = capabilities?["driver"]?.boolValue ?? false
        }
        guard let result = try? await roster.request("groups.list", ["limit": .number(100)]),
              case .array(let rows)? = result["rooms"] else {
            isLoaded = true
            return
        }
        rooms = rows.compactMap(GroupRoom.parse).filter { $0.disbandedAt == nil }
        isLoaded = true
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

    /// The latest line and whether the room waits on the person, for the roster row.
    func summary(for id: String) -> (preview: String?, needsYou: Bool) {
        guard let chat = chats[id] else { return (nil, false) }
        return (chat.preview, chat.pendingApproval != nil)
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

    @ObservationIgnored private weak var roster: BotRoster?
    @ObservationIgnored private weak var rooms: GroupRooms?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastSeq = 0

    init(room: GroupRoom, roster: BotRoster, rooms: GroupRooms) {
        self.room = room
        self.roster = roster
        self.rooms = rooms
    }

    var memberStates: [String: RoomTranscript.MemberState] { RoomTranscript.memberStates(events) }
    var currentRound: Int { RoomTranscript.currentRound(events) }

    var preview: String? {
        for item in items.reversed() {
            switch item {
            case .member(_, let memberID, let text, _): return "\(member(memberID)?.displayName ?? memberID): \(text)"
            case .user(_, let text, _): return text
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
                try? await Task.sleep(for: self.isWorking || self.pendingApproval != nil ? .milliseconds(1200) : .seconds(5))
            }
        }
    }

    func close() {
        poller?.cancel()
        poller = nil
    }

    func poll() async {
        guard let roster, roster.isConnected else { return }
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
                if let name = fresh.last(where: { $0.kind == "room.renamed" })?.payload["name"]?.stringValue { room.name = name }
                room.updatedAt = fresh.last?.createdAt ?? room.updatedAt
                rooms?.touched(room)
            }
            let state = try await roster.request("groups.state", ["room_id": .string(room.id)])
            readDriverStatus(state["driver_status"])
            error = nil
        } catch {
            self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
        }
    }

    private func readDriverStatus(_ status: JSONValue?) {
        isWorking = (status?["working"]?.boolValue ?? false) || !RoomTranscript.isSettled(events)
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

    // MARK: Actions

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let roster else { return }
        draftReferences = []
        draft = ""
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
                draft = text
                self.error = (error as? GatewayRPCError)?.message ?? error.localizedDescription
                isWorking = false
            }
        }
    }

    func stop() {
        guard let roster else { return }
        Task {
            _ = try? await roster.request("groups.stop", ["room_id": .string(room.id), "cancel_id": .string(UUID().uuidString)])
            await poll()
        }
    }

    func respond(_ choice: ApprovalChoice) {
        guard let roster, let approval = pendingApproval else { return }
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
