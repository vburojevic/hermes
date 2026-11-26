import Foundation

/// One message's `prompt.submit` on the gateway socket (`docs/follow-ups.md` §4), built for the
/// dispatcher that serves it. The two take different keys:
///
/// - The legacy dispatcher (Hermes Agent before 0.23.3, and 0.23.3 and newer without the session
///   authority) forbids unknown keys and answers 4000 for one (`tui_gateway/contracts/base.py`
///   `extra="forbid"`), so it gets exactly the keys it always got.
/// - The session authority (`gateway.ready` says `session_authority`) admits a message only with a
///   `submission_id` and answers 4001 `invalid_params` without one
///   (`gateway/session_controls.py` `submission`). A repeated id is the same admission, never a
///   second turn, so the id is minted once per message and kept for every resend of it.
public struct PromptSubmitContract: Sendable, Equatable {
    public var sessionID: String
    public var text: String
    /// A busy chat queues the message rather than steering its turn with it.
    public var queued: Bool
    /// Keys both dispatchers take, such as a spoken turn's (`VoiceTurn.submitParams`).
    public var extras: [String: JSONValue]
    /// The message's identity on the session authority, the same on every try.
    public let submissionID: String

    public init(
        sessionID: String,
        text: String,
        queued: Bool = true,
        extras: [String: JSONValue] = [:],
        submissionID: String = UUID().uuidString
    ) {
        self.sessionID = sessionID
        self.text = text
        self.queued = queued
        self.extras = extras
        self.submissionID = submissionID
    }

    /// The request's params for a socket that is (`sessionAuthority`) or isn't served by the session
    /// authority.
    public func params(sessionAuthority: Bool) -> [String: JSONValue] {
        var params = extras
        params["session_id"] = .string(sessionID)
        params["text"] = .string(text)
        if queued { params["queued"] = .bool(true) }
        if sessionAuthority { params["submission_id"] = .string(submissionID) }
        return params
    }

    /// Whether Hermes refused the message only because this socket's hold on the chat is stale, so
    /// resuming the chat and sending again is safe. Every other refusal is shown.
    ///
    /// Besides a session Hermes doesn't have (`isSessionNotFound`), the session authority refuses a
    /// submit for a chat this socket hasn't resumed with 4001 `permission_denied`
    /// (`gateway/session_controls.py` `submission`: a socket holds only the chats it resumed or
    /// created, and a reconnected socket holds none). It refuses before reading the message, so
    /// nothing was admitted, and `session.resume` gives the socket the chat. A second refusal after
    /// the resume is a real denial and is shown.
    public static func isStaleSession(_ error: any Error) -> Bool {
        guard let error = error as? GatewayRPCError else { return false }
        return error.isSessionNotFound || (error.code == 4001 && error.refusalReason == "permission_denied")
    }

    /// Sends `submit`, and on a stale session resumes the chat once (`resume` answers the new
    /// runtime id) and sends the same message again, with the same submission id. A second stale
    /// session, or any other refusal, is thrown. Runs on the caller's actor, which `send` and
    /// `resume` belong to.
    public static func submittingOnce<Answer>(
        _ submit: PromptSubmitContract,
        isolation: isolated (any Actor)? = #isolation,
        send: (PromptSubmitContract) async throws -> Answer,
        resume: () async throws -> String
    ) async throws -> Answer {
        do {
            return try await send(submit)
        } catch where isStaleSession(error) {
            var again = submit
            again.sessionID = try await resume()
            return try await send(again)
        }
    }
}
