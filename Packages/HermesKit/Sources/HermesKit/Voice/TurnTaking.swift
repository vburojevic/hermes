import Foundation

/// Voice activity from the microphone's level (`docs/voice.md` §4.2): fast and deterministic, so
/// barge-in and the end of a turn don't wait for words. It runs on the echo-cancelled input, so
/// the Bot's own voice isn't speech. The noise floor follows the room; speech is a level well
/// above it, held briefly, and ends after a short hangover.
public struct VoiceActivityDetector: Sendable {
    public enum Event: Sendable, Equatable {
        case started(at: TimeInterval)
        /// `at` is the end of the last voiced frame, not when the hangover ran out.
        case ended(at: TimeInterval)
    }

    /// Above the floor by this factor (about 10 dB) counts as voice.
    public var ratio: Float = 3.2
    /// Never quieter than this RMS (about −46 dBFS): a silent room isn't a reason to hear breath.
    public var minimum: Float = 0.005
    /// Voice for this long before it's speech.
    public var attack: TimeInterval = 0.06
    /// Quiet for this long before speech has ended.
    public var hangover: TimeInterval = 0.18

    public private(set) var isSpeaking = false
    public private(set) var floor: Float = 0.003
    private var voicedSince: TimeInterval?
    private var lastVoiced: TimeInterval?

    public init() {}

    /// The threshold now.
    public var threshold: Float { max(minimum, floor * ratio) }

    /// One frame of input (about 20 ms): its RMS, linear 0…1, and when it was heard.
    public mutating func process(rms: Float, at time: TimeInterval) -> Event? {
        let voiced = rms >= threshold
        // The floor follows the room: down quickly, up slowly (a few seconds), so steady noise
        // (a fan, a car) stops counting while speech, which keeps dipping, still does.
        floor = rms < floor ? floor * 0.7 + rms * 0.3 : floor * 0.995 + rms * 0.005
        if voiced {
            lastVoiced = time
            if voicedSince == nil { voicedSince = time }
            if !isSpeaking, let since = voicedSince, time - since >= attack {
                isSpeaking = true
                return .started(at: since)
            }
        } else {
            voicedSince = nil
            if isSpeaking, let last = lastVoiced, time - last >= hangover {
                isSpeaking = false
                return .ended(at: last)
            }
        }
        return nil
    }
}

/// When a spoken turn is over (`docs/voice.md` §4.2): after a pause of Short 0.6 s, Normal 0.9 s
/// or Long 1.4 s since the last speech or words, longer by 0.4 s when the last word sounds
/// unfinished ("and", "so", "um"). Nothing is polled: the caller waits for `deadline` and asks
/// again whenever something new is heard.
public struct Endpointer: Sendable {
    public enum Pause: String, Sendable, CaseIterable {
        case short, normal, long

        public var seconds: TimeInterval {
            switch self {
            case .short: 0.6
            case .normal: 0.9
            case .long: 1.4
            }
        }
    }

    public static let unfinishedExtra: TimeInterval = 0.4

    public var pause: Pause
    public private(set) var words = ""
    private var speaking = false
    /// The last speech or words heard: where "the end of speech" is measured from.
    public private(set) var lastActivity: TimeInterval?

    public init(pause: Pause = .normal) {
        self.pause = pause
    }

    public mutating func speechStarted(at time: TimeInterval) {
        speaking = true
        lastActivity = max(lastActivity ?? time, time)
    }

    public mutating func speechEnded(at time: TimeInterval) {
        speaking = false
        lastActivity = max(lastActivity ?? time, time)
    }

    /// The transcript so far changed (volatile or final).
    public mutating func heard(_ words: String, at time: TimeInterval) {
        guard words != self.words else { return }
        self.words = words
        lastActivity = max(lastActivity ?? time, time)
    }

    /// When the turn ends if nothing more is heard; `nil` while speaking or before any words.
    public var deadline: TimeInterval? {
        guard !speaking, let lastActivity, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return lastActivity + pause.seconds + (Self.soundsUnfinished(words) ? Self.unfinishedExtra : 0)
    }

    public func isComplete(at time: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return time >= deadline
    }

    /// Starts the next turn.
    public mutating func reset() {
        words = ""
        speaking = false
        lastActivity = nil
    }

    private static let trailing: Set<String> = [
        "and", "so", "but", "or", "because", "um", "uh", "er", "erm", "hmm", "like", "then", "if", "also",
        "the", "a", "an", "to", "with", "of", "for", "my", "our", "your", "is", "are", "that", "which", "when",
    ]

    /// The last word is one people say before carrying on.
    public static func soundsUnfinished(_ words: String) -> Bool {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence that ended with a full stop or a question is finished, whatever its last word.
        if let last = trimmed.last, ".?!".contains(last) { return false }
        guard let word = trimmed.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last else { return false }
        return trailing.contains(String(word))
    }
}
