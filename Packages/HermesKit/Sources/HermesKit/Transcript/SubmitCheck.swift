import Foundation

/// Whether a message reached Hermes when the answer to sending it never came (the socket closed or
/// the answer was too late). Sending it again could run it twice, so the stored chat is asked.
public enum SubmitCheck {
    /// The stored chat has the message: a user message stored after the newest one the chat knew
    /// before sending (`knownNewestID`), from around the time it was sent (the gateway's clock may
    /// differ a little), with the same words. An identical earlier message ("ok", then "ok") is
    /// told apart by its id.
    public static func arrived(
        _ text: String, sentAt: Date, knownNewestID: Int?, in messages: [SessionMessage], clockSkew: TimeInterval = 120
    ) -> Bool {
        let wanted = normalized(text)
        guard !wanted.isEmpty else { return false }
        return sentSince(sentAt, knownNewestID: knownNewestID, in: messages, clockSkew: clockSkew)
            .contains { normalized($0.content.text) == wanted }
    }

    /// The stored chat has some message from the person sent since, in other words: it may be this
    /// one stored differently (with its attachments, say), so its absence isn't proven.
    public static func anySent(
        since sentAt: Date, knownNewestID: Int?, in messages: [SessionMessage], clockSkew: TimeInterval = 120
    ) -> Bool {
        !sentSince(sentAt, knownNewestID: knownNewestID, in: messages, clockSkew: clockSkew).isEmpty
    }

    private static func sentSince(
        _ sentAt: Date, knownNewestID: Int?, in messages: [SessionMessage], clockSkew: TimeInterval
    ) -> [SessionMessage] {
        messages.filter { message in
            guard message.role == "user" else { return false }
            if let knownNewestID, let id = message.id, id <= knownNewestID { return false }
            if let timestamp = message.timestamp, timestamp < sentAt.addingTimeInterval(-clockSkew) { return false }
            return true
        }
    }

    /// Words only: whitespace and line breaks as Hermes may store them don't matter.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
