import Foundation

/// The session a `command.dispatch` runs in (`docs/notifications.md` §1.2).
///
/// The legacy dispatcher runs a command without a session in the profile the gateway was started
/// in, so the plugins' commands (`/app-push`, `/app-widgets`, `/memory`) went without one. The
/// session authority (Hermes Agent 0.23.3 and newer, `gateway.ready` says `session_authority`)
/// authorizes every command against a session first and refuses an empty session id with 4001
/// `not_found` (`gateway/session_commands.py` `execute_command`, `gateway/session_authority.py`
/// `authorize`). So on that socket a command without a session of its own carries the profile's
/// Bot Chat: the forever chat Bot Mode already keeps, found by its title, resumed, or created
/// hidden the way Bot Mode creates it. No turn runs in it; a plugin command only reads it.
public enum CommandDispatchSession {
    public static let method = "command.dispatch"

    /// Whether this request needs a session added: a `command.dispatch` on a session authority
    /// that names none. Every other request, and every request on the legacy dispatcher, goes as
    /// it is, since that dispatcher answers exactly as it always has.
    public static func needsSession(method: String, params: [String: JSONValue], sessionAuthority: Bool) -> Bool {
        guard sessionAuthority, method == Self.method else { return false }
        return (params["session_id"]?.stringValue ?? "").isEmpty
    }

    /// The profile whose session the command needs: the one it names (the authority routes the
    /// request to that profile and wants that profile's session), else the gateway's own.
    public static func profile(of params: [String: JSONValue]) -> String? {
        guard let profile = params["profile"]?.stringValue, !profile.isEmpty else { return nil }
        return profile
    }

    /// Sends `params` with `session(nil)`'s session added. When Hermes answers that the added
    /// session is gone (`isSessionNotFound`: closed or deleted elsewhere), asks `session` again
    /// with the one that failed, once, and sends once more; a second refusal is thrown, never
    /// retried. Runs on the caller's actor, which `session` and `send` belong to.
    public static func sending<Answer>(
        _ params: [String: JSONValue],
        isolation: isolated (any Actor)? = #isolation,
        session: (_ stale: String?) async throws -> String,
        send: ([String: JSONValue]) async throws -> Answer
    ) async throws -> Answer {
        var params = params
        let first = try await session(nil)
        params["session_id"] = .string(first)
        do {
            return try await send(params)
        } catch let error as GatewayRPCError where error.isSessionNotFound {
            params["session_id"] = .string(try await session(first))
            return try await send(params)
        }
    }

    /// The runtime id of `profile`'s Bot Chat on the socket `request` speaks to: found by its title
    /// (hidden included) and resumed, or created hidden with that title when the profile has none,
    /// as Bot Mode does (`BotRoster.resolveBotChat`, `ConversationModel.ensureRuntime`). Without a
    /// profile, the gateway's own (Hermes reads a missing `profile` as its own home).
    public static func openBotChat(
        profile: String?,
        isolation: isolated (any Actor)? = #isolation,
        request: (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue
    ) async throws -> String {
        var scope: [String: JSONValue] = [:]
        if let profile { scope["profile"] = .string(profile) }
        let listed = try await request("session.list", scope.merging([
            "title": .string(botChatTitle), "include_hidden": .bool(true), "limit": .number(200),
        ]) { $1 })
        // Fails closed: a listing that can't be read never reads as "no chat", or a second
        // forever chat would be made.
        guard case .array(let sessions)? = listed["sessions"] else { throw HermesError.invalidResponse("session.list") }
        if let row = sessions.first(where: { $0["title"]?.stringValue == nil || $0["title"]?.stringValue == botChatTitle }),
           let stored = row["resolved_id"]?.stringValue ?? row["id"]?.stringValue {
            let resumed = try await request("session.resume", scope.merging([
                "session_id": .string(stored), "omit_messages": .bool(true),
            ]) { $1 })
            guard let runtime = resumed["session_id"]?.stringValue else { throw HermesError.invalidResponse("session.resume") }
            return runtime
        }
        let created = try await request("session.create", scope.merging([
            "title": .string(botChatTitle), "hidden": .bool(true), "follow_profile_config": .bool(true),
        ]) { $1 })
        guard let runtime = created["session_id"]?.stringValue else { throw HermesError.invalidResponse("session.create") }
        return runtime
    }

    /// The gateway has no such command: the legacy dispatcher answers 4018, the session authority
    /// 4001 `unsupported_command` (`gateway/session_commands.py` `_skill_directive`). Both mean
    /// the plugin isn't installed or isn't on in that profile.
    public static func isCommandMissing(_ error: any Error) -> Bool {
        guard let error = error as? GatewayRPCError else { return false }
        return error.code == 4018 || (error.code == 4001 && error.refusalReason == "unsupported_command")
    }
}
