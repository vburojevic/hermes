import Foundation

/// The `hermes-app-widgets` gateway plugin's commands (`Tools/hermes-app-widgets/README.md`,
/// `docs/widgets.md` §11).
///
/// Like the push plugin's, they run through `command.dispatch {name, arg: "<command> <json>"}`
/// and answer one line of JSON in `output`. Error 4018 means the plugin isn't installed.
public struct AppWidgetsClient: Sendable {
    public enum Failure: Error, Equatable {
        case notInstalled
        case refused(String)
        case malformed
    }

    /// Sends one request over whichever socket the caller has.
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    let transport: Transport
    /// The profile a chat runs under, for commands about one chat.
    let profile: String?
    /// A live chat of that profile, for commands about none: Hermes runs a plugin command without a
    /// session in the profile it was launched in, whatever `profile` says (`command.dispatch`).
    let session: String?

    public init(profile: String? = nil, session: String? = nil, transport: @escaping Transport) {
        self.profile = profile
        self.session = session
        self.transport = transport
    }

    /// Runs `/app-widgets <command> <json>` and returns the plugin's JSON answer.
    public func run(_ command: String, _ arguments: [String: JSONValue], sessionID: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["name": .string("app-widgets"), "arg": .string(command + " " + WidgetAnswer.canonical(.object(arguments)))]
        if let sessionID = sessionID ?? session { params["session_id"] = .string(sessionID) }
        if let profile { params["profile"] = .string(profile) }
        let result: JSONValue
        do {
            result = try await transport("command.dispatch", params)
        } catch let error as GatewayRPCError where error.code == 4018 {
            throw Failure.notInstalled
        }
        guard let output = result["output"]?.stringValue,
              let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("{") }),
              let answer = JSONValue.parse(Data(line.utf8))
        else { throw Failure.malformed }
        if answer["ok"]?.boolValue == false {
            throw Failure.refused(answer["error"]?.stringValue ?? "refused")
        }
        return answer
    }

    // MARK: Commands

    /// Marks a chat as the app's, by both of its ids: the plugin then sends widgets to it, not text.
    public func markSession(runtimeID: String, storedID: String) async throws {
        _ = try await run("session", ["session_id": .string(runtimeID), "stored_session_id": .string(storedID)], sessionID: runtimeID)
    }

    /// Marks many chats at once by their stored ids (`session_ids`, at most 500 a call; plugin 1.1.1):
    /// chats this device knows but hasn't opened still get widgets.
    public func markSessions(_ storedIDs: [String]) async throws {
        _ = try await run("session", ["session_ids": .array(storedIDs.prefix(500).map(JSONValue.string))])
    }

    /// Marks a Bot group chat: its members' replies then carry their widgets as inline blocks.
    public func markRoom(_ roomID: String) async throws {
        _ = try await run("room", ["room_id": .string(roomID)])
    }

    /// Registers this device's signing key (P-256, X9.63, base64). Answers its fingerprint.
    @discardableResult
    public func registerKey(deviceID: String, publicKey: String, name: String) async throws -> String {
        let answer = try await run("keys.register", ["device_id": .string(deviceID), "public_key": .string(publicKey), "name": .string(name)])
        guard let fingerprint = answer["fingerprint"]?.stringValue else { throw Failure.malformed }
        return fingerprint
    }

    public func removeKey(deviceID: String) async throws {
        _ = try await run("keys.remove", ["device_id": .string(deviceID)])
    }

    /// A widget's newest revision, or one revision, from the plugin's store.
    public func widget(_ id: String, rev: Int? = nil) async throws -> JSONValue {
        var arguments: [String: JSONValue] = ["id": .string(id)]
        if let rev { arguments["rev"] = .number(Double(rev)) }
        let answer = try await run("get", arguments)
        guard let payload = answer["payload"], case .object = payload else { throw Failure.malformed }
        return payload
    }
}
