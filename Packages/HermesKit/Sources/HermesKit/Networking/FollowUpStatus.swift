import Foundation

/// What the gateway did with a message sent while a turn ran: `prompt.submit` (`streaming`, `queued`,
/// `steered`, `redirected`), `session.steer` and `session.redirect` (`queued`, `redirected`, `rejected`).
///
/// `session.steer` answers `queued` for a steer it accepted but hasn't read yet; `prompt.submit` and
/// `session.redirect` answer `queued` for a message held for the next turn.
public enum FollowUpStatus: String, Sendable, Equatable {
    /// The session was idle: the message started a turn of its own.
    case streaming
    case queued
    case steered
    /// Accepted as a redirect. During a tool call Hermes delivers it like a steer instead.
    case redirected
    /// No turn is running (a steer that came too late).
    case rejected

    public init?(result: JSONValue?) {
        guard let raw = result?["status"]?.stringValue, let status = FollowUpStatus(rawValue: raw) else { return nil }
        self = status
    }
}

/// Hermes' own queue: the message it holds for the next turn (images, files, a steer or redirect
/// while it compacts), as `session.resume` reports it (`queued: {user}`).
public enum GatewayQueue {
    public static func queuedPrompt(in snapshot: JSONValue) -> String? {
        let text = (snapshot["queued"]?["user"] ?? snapshot["queued_prompt"]?["user"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// `display.busy_input_mode` from `config.get {key: "busy"}`.
    public static func busyMode(in result: JSONValue) -> String? {
        result["value"]?.stringValue
    }
}
