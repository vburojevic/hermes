import Foundation

/// Audio a Bot sent (`docs/voice.md` §2): a `MEDIA:<path>` line in a reply, from the
/// `text_to_speech` tool or a Bot that sends audio. `[[audio_as_voice]]` before it makes it a voice
/// message. Played from the gateway (`/api/files/stream?path=`), drawn as a `listenStrip`.
public struct AgentAudio: Hashable, Sendable, Identifiable {
    public var path: String
    /// A voice message (`[[audio_as_voice]]`), not just a file.
    public var isVoice: Bool

    public init(path: String, isVoice: Bool) {
        self.path = path
        self.isVoice = isVoice
    }

    public var id: String { path }

    /// "summary.mp3".
    public var fileName: String { (path as NSString).lastPathComponent }

    /// Hermes's audio list (`gateway/platforms/base.py` `_AUDIO_MIME_TYPES`).
    public static let extensions: Set<String> = ["ogg", "opus", "mp3", "m2a", "wav", "m4a", "flac"]

    /// The reply's text without its audio lines, and the audio, in order. Other `MEDIA:` lines
    /// (images, documents) stay for ``TranscriptBuilder/cleanAssistantText(_:)``. Like Hermes,
    /// `[[audio_as_voice]]` applies to the whole message, and only to audio.
    public static func split(_ text: String) -> (text: String, audio: [AgentAudio]) {
        guard text.contains("MEDIA:") || text.contains("[[audio_as_voice]]") else { return (text, []) }
        let isVoice = text.contains("[[audio_as_voice]]")
        var audio: [AgentAudio] = []
        var kept: [String] = []
        var inCode = false
        for line in text.replacingOccurrences(of: "[[audio_as_voice]]", with: "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A path in a code block is an example, not something to play.
            if trimmed.hasPrefix("```") { inCode.toggle() }
            if !inCode, let path = mediaPath(trimmed),
               extensions.contains((path as NSString).pathExtension.lowercased()) {
                if !audio.contains(where: { $0.path == path }) {
                    audio.append(AgentAudio(path: path, isVoice: isVoice))
                }
                continue
            }
            kept.append(line)
        }
        return (kept.joined(separator: "\n"), audio)
    }

    /// The path of a `MEDIA:` line, quotes and backticks removed (the TUI's `MEDIA_LINE_RE`).
    static func mediaPath(_ line: String) -> String? {
        let quotes = CharacterSet(charactersIn: "`\"'*_")
        let bare = line.trimmingCharacters(in: quotes)
        guard bare.hasPrefix("MEDIA:") else { return nil }
        let path = bare.dropFirst("MEDIA:".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes)
        return path.isEmpty ? nil : path
    }
}

/// A voice message the person sent (`docs/voice.md` §2): its transcript is the message text and
/// the recording is attached with `file.attach` as `voice-<uuid>.m4a`, which every device can play.
public enum VoiceMessageFile {
    /// `voice-<uuid>.m4a`.
    public static func name(id: UUID = UUID()) -> String {
        "voice-\(id.uuidString.lowercased()).m4a"
    }

    public static func isVoiceMessage(_ name: String) -> Bool {
        let file = (name as NSString).lastPathComponent.lowercased()
        guard file.hasPrefix("voice-"), file.hasSuffix(".m4a") else { return false }
        return UUID(uuidString: String(file.dropFirst("voice-".count).dropLast(".m4a".count))) != nil
    }

    /// The gateway path of the recording a message carries (its `@file:` reference), if it's a
    /// voice message.
    public static func path(in text: String) -> String? {
        for word in text.split(whereSeparator: \.isWhitespace) where word.hasPrefix("@file:") {
            let path = word.dropFirst("@file:".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if isVoiceMessage(path) { return path }
        }
        return nil
    }
}

/// Replies in kind (`docs/voice.md` §2, Settings → Voice & Audio → Voice replies): which replies
/// open with a listen strip of the Bot's voice.
public enum VoiceReplies {
    public enum Setting: String, Sendable, CaseIterable {
        /// After a voice message (the default).
        case whenISpeak
        case always
        case never
    }

    /// The ids of the replies that get the strip: each reply after a voice message (until the
    /// person writes again), or every reply, or none.
    public static func turns(in items: [TranscriptItem], setting: Setting) -> Set<String> {
        guard setting != .never else { return [] }
        var answering = setting == .always
        var turns: Set<String> = []
        for item in items {
            switch item {
            case .user(let entry) where entry.sender == nil && entry.routineName == nil && !entry.isSteer:
                answering = setting == .always || entry.voicePath != nil
            case .assistant(let turn):
                if answering { turns.insert(turn.id) }
            default:
                break
            }
        }
        return turns
    }
}
