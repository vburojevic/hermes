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

    /// Where the person is: a device showing a chat gets no push for it; `live` chats are ones
    /// the app hears over its own connection and notifies about itself (the Mac).
    /// - Parameter sync: leaving (`away`), the chats to keep current while the app is away: a turn
    ///   ending in one wakes the app with a background push (`sync`). Older plugins ignore it.
    @discardableResult
    public func setPresence(_ presence: Presence, deviceID: String, visibleChat: String? = nil, live: [String]? = nil,
                            sync: [String]? = nil) async throws -> Int {
        var args: [String: JSONValue] = ["device_id": .string(deviceID), "state": .string(presence.rawValue)]
        if let visibleChat { args["session_id"] = .string(visibleChat) }
        if let live { args["live"] = .array(live.map(JSONValue.string)) }
        if let sync { args["sync"] = .array(sync.map(JSONValue.string)) }
        let answer = try await run("presence", args)
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
            relayError: answer["relay_error"]?.stringValue
        )
    }

    /// Asks the gateway to push a test notice now.
    public func test(deviceID: String) async throws {
        _ = try await run("test", ["device_id": .string(deviceID)])
    }

    static func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
