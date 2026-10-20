import Foundation

/// A spoken turn's extras on `prompt.submit` (`docs/voice.md` §4.1, §10;
/// `tui_gateway/contracts/prompt_voice.py`):
/// - `surface: "voice-live"`, so Hermes knows it's a conversation;
/// - `voice_context`, the recent spoken exchange, which Hermes adds to the model's input only;
/// - `voice_turn`, Hermes Voice's turns, which run on the gateway's voice model (a Realtime
///   delegation doesn't set it);
/// - `interrupted`, when the person cut the last reply off.
public struct VoiceTurn: Sendable, Equatable {
    public var isVoiceTurn: Bool
    public var context: String
    public var interrupted: Bool

    public init(isVoiceTurn: Bool = true, context: String = "", interrupted: Bool = false) {
        self.isVoiceTurn = isVoiceTurn
        self.context = context
        self.interrupted = interrupted
    }

    /// Hermes keeps at most this much of `voice_context`.
    public static let contextLimit = 6000

    public var submitParams: [String: JSONValue] {
        var params: [String: JSONValue] = ["surface": .string("voice-live")]
        if isVoiceTurn { params["voice_turn"] = .bool(true) }
        if !context.isEmpty { params["voice_context"] = .string(context) }
        if interrupted { params["interrupted"] = .bool(true) }
        return params
    }

    /// "User: …" / "Voice assistant: …" lines, oldest first, as Hermes Desktop builds them: the
    /// newest that fit in the limit, each cut to 1200 characters.
    public static func context(_ lines: [(isUser: Bool, text: String)]) -> String {
        var kept: [String] = []
        var size = 0
        for line in lines.reversed() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let entry = (line.isUser ? "User: " : "Voice assistant: ") + String(text.prefix(1200))
            guard size + entry.count + 1 <= contextLimit else { break }
            kept.append(entry)
            size += entry.count + 1
        }
        return kept.reversed().joined(separator: "\n")
    }
}
