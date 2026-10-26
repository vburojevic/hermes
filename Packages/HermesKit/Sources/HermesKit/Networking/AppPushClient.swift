import Foundation
import HermesPush

/// The `hermes-app-push` gateway plugin's commands (`Tools/hermes-app-push/README.md`).
///
/// Hermes plugins can't add gateway RPC methods, so the app runs the plugin's `/app-push`
/// command through `command.dispatch {name, arg: "<command> <json>"}` and reads one line of
/// JSON from `output`. Error 4018 means the plugin isn't installed (or isn't enabled).
public struct AppPushClient: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The gateway answered, but has no `/app-push` command.
        case notInstalled
        /// The plugin refused (bad input, unknown device).
        case refused(String)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "The Hermes app plugin isn't installed on this gateway."
            case .refused(let reason): reason
            case .malformed: "The Hermes app plugin answered in a way this app doesn't understand."
            }
        }
    }

    public struct Registration: Sendable, Equatable {
        public var installationID: String
        public var gatewayName: String
        /// `ok`, or why the gateway can't reach the relay.
        public var relay: String
        public var version: String?
    }

    public struct Status: Sendable, Equatable {
        public var version: String?
        public var registered: Bool
        public var open: Int
        public var installationID: String?
        public var relayError: String?
        /// The last six hours' reads on any device (plugin 1.4.6; nil from older ones).
        public var reads: ReadMarks? = nil
    }

    /// What `presence` answers: the open requests and, from plugin 1.4.6, the last six hours' reads
    /// on any device, so a group chat read elsewhere reaches this one (`docs/notifications.md` §2).
    public struct PresenceAnswer: Sendable, Equatable {
        public var open: Int
        public var reads: ReadMarks?
    }

    /// Sends one request over whichever socket the caller has.
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    public init(socket: GatewaySocket) {
        self.init { method, params in try await socket.request(method, params, timeout: .seconds(20)) }
    }

    /// Runs `/app-push <command> <json>` and returns the plugin's JSON answer.
    public func run(_ command: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let encoded = try JSONEncoder().encode(JSONValue.object(arguments))
        let arg = command + " " + (String(data: encoded, encoding: .utf8) ?? "{}")
        let result: JSONValue
        do {
            result = try await transport("command.dispatch", ["name": .string("app-push"), "arg": .string(arg)])
        } catch let error as GatewayRPCError where error.code == 4018 {
            throw Failure.notInstalled
        }
        guard let output = result["output"]?.stringValue,
              let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("{") }),
              let answer = JSONValue.parse(Data(line.utf8))
        else { throw Failure.malformed }
        if answer["ok"]?.boolValue == false {
            throw Failure.refused(answer["error"]?.stringValue ?? answer["reason"]?.stringValue ?? "refused")
        }
        return answer
    }

    // MARK: Commands

    public struct Device: Sendable {
        public var id: String
        /// APNs device token, hex.
        public var token: String
        /// The app's bundle id (the APNs topic).
        public var topic: String
        /// `development` (sandbox) or `production`.
        public var environment: String
        public var publicKey: String
        public var platform: String
        public var name: String
        public var appVersion: String
        /// Debug simulator builds: where the mock's fake relay delivers (`simctl push`).
        public var simulator: String?

        public init(id: String, token: String, topic: String, environment: String, publicKey: String,
                    platform: String, name: String, appVersion: String, simulator: String? = nil) {
            self.id = id
            self.token = token
            self.topic = topic
            self.environment = environment
            self.publicKey = publicKey
            self.platform = platform
            self.name = name
            self.appVersion = appVersion
            self.simulator = simulator
        }
    }

    public func register(_ device: Device, preferences: PushPreferences) async throws -> Registration {
        var args: [String: JSONValue] = [
            "device_id": .string(device.id), "token": .string(device.token), "topic": .string(device.topic),
            "environment": .string(device.environment), "public_key": .string(device.publicKey),
            "platform": .string(device.platform), "name": .string(device.name),
            "app_version": .string(device.appVersion), "preferences": try Self.json(preferences),
        ]
        if let simulator = device.simulator { args["simulator"] = .string(simulator) }
        let answer = try await run("register", args)
        guard let id = answer["gateway"]?["id"]?.stringValue else { throw Failure.malformed }
        return Registration(
            installationID: id, gatewayName: answer["gateway"]?["name"]?.stringValue ?? "",
            relay: answer["relay"]?.stringValue ?? "ok", version: answer["version"]?.stringValue
        )
    }

    public func unregister(deviceID: String) async throws {
        _ = try await run("unregister", ["device_id": .string(deviceID)])
    }

    public func setPreferences(_ preferences: PushPreferences, deviceID: String) async throws {
        _ = try await run("preferences", ["device_id": .string(deviceID), "preferences": try Self.json(preferences)])
    }

    public enum Presence: String, Sendable {
        case foreground, running, away
    }

    /// Chats by session id and group chats by room id, as the plugin names them.
    public struct ChatLists: Sendable, Hashable {
        public var chats: [String]
        public var rooms: [String]

        public init(chats: [String] = [], rooms: [String] = []) {
            self.chats = chats
            self.rooms = rooms
        }

        var json: JSONValue {
            .object(["chats": .array(chats.map(JSONValue.string)), "rooms": .array(rooms.map(JSONValue.string))])
        }
    }

    /// Where the person is: a device showing a chat gets no push for it; `live` chats are ones
    /// the app hears over its own connection and notifies about itself (the Mac).
    /// - Parameters:
    ///   - sync: leaving (`away`), the chats to keep current while the app is away: a turn ending
    ///     in one wakes the app with a background push (`sync`). Older plugins ignore it.
    ///   - unread: leaving, the chats the app icon badge counts, `muted` the muted ones,
    ///     `listed` every chat the app lists (only those may count) and `badgeOthers` what other
    ///     gateways add to it: the plugin keeps the badge right while the app is away (plugin 1.4.0,
    ///     `listed` 1.4.2). `badge` is what the icon shows as the app leaves: when that isn't the
    ///     plugin's count, a badge push sets it right (1.4.5).
    @discardableResult
    public func setPresence(_ presence: Presence, deviceID: String, visibleChat: String? = nil, live: [String]? = nil,
                            sync: [String]? = nil, unread: ChatLists? = nil, muted: ChatLists? = nil,
                            listed: ChatLists? = nil, badgeOthers: Int? = nil, badge: Int? = nil) async throws -> PresenceAnswer {
        var args: [String: JSONValue] = ["device_id": .string(deviceID), "state": .string(presence.rawValue)]
        if let visibleChat { args["session_id"] = .string(visibleChat) }
        if let live { args["live"] = .array(live.map(JSONValue.string)) }
        if let sync { args["sync"] = .array(sync.map(JSONValue.string)) }
        if let unread { args["unread"] = unread.json }
        if let muted { args["muted"] = muted.json }
        if let listed { args["listed"] = listed.json }
        if let badgeOthers { args["badge_others"] = .number(Double(max(0, badgeOthers))) }
        if let badge { args["badge"] = .number(Double(max(0, badge))) }
        let answer = try await run("presence", args)
        return PresenceAnswer(open: Int(answer["open"]?.doubleValue ?? 0), reads: Self.reads(in: answer))
    }

    /// Chats read on this device (`docs/notifications.md` §2 Reading): the plugin clears them on
    /// the person's other devices. Returns the open requests. Plugin 1.4.0; older ones refuse it.
    @discardableResult
    public func read(deviceID: String, chats: [String], rooms: [String]) async throws -> Int {
        let answer = try await run("read", ["device_id": .string(deviceID), "chats": .array(chats.map(JSONValue.string)),
                                            "rooms": .array(rooms.map(JSONValue.string))])
        return Int(answer["open"]?.doubleValue ?? 0)
    }

    /// A Live Activity started (`token`) or ended (`nil`) for a chat.
    public func setActivity(deviceID: String, token: String?, sessionID: String?, activityID: String?) async throws {
        var args: [String: JSONValue] = ["device_id": .string(deviceID)]
        if let token { args["token"] = .string(token) }
        if let sessionID { args["session_id"] = .string(sessionID) }
        if let activityID { args["activity_id"] = .string(activityID) }
        _ = try await run("activity", args)
    }

    public func status(deviceID: String) async throws -> Status {
        let answer = try await run("status", ["device_id": .string(deviceID)])
        return Status(
            version: answer["version"]?.stringValue,
            registered: answer["registered"]?.boolValue ?? false,
            open: Int(answer["open"]?.doubleValue ?? 0),
            installationID: answer["gateway"]?["id"]?.stringValue,
            relayError: answer["relay_error"]?.stringValue,
            reads: Self.reads(in: answer)
        )
    }

    /// An answer's `read`, shaped as a notice's (`{chats: [[id, at], …], rooms}`); a list this build
    /// can't read costs only the reads, never the answer.
    static func reads(in answer: JSONValue) -> ReadMarks? {
        guard let read = answer["read"], let data = try? JSONEncoder().encode(read),
              let marks = try? JSONDecoder().decode(ReadMarks.self, from: data), !marks.isEmpty else { return nil }
        return marks
    }

    /// Asks the gateway to push a test notice now.
    public func test(deviceID: String) async throws {
        _ = try await run("test", ["device_id": .string(deviceID)])
    }

    static func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
