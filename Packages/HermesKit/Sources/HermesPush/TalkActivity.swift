import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// A call on the Lock Screen and in the Dynamic Island (`liveActivityTalk`, `islandTalk`,
/// `islandTalkExpanded`; `docs/voice.md` §4.4). Started and updated by the app only: nothing
/// about a call goes through push.
public struct TalkActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Phase: String, Codable, Hashable, Sendable {
            case connecting, listening, working, speaking, needsYou, onHold
        }

        public var phase: Phase
        public var isMuted: Bool
        /// The last words heard or said, short (quoted under the title).
        public var line: String?

        public init(phase: Phase, isMuted: Bool, line: String? = nil) {
            self.phase = phase
            self.isMuted = isMuted
            self.line = line
        }
    }

    /// "Hermes", or the Bot.
    public var title: String
    public var face: FaceLook?
    public var startedAt: Date

    public init(title: String, face: FaceLook?, startedAt: Date) {
        self.title = title
        self.face = face
        self.startedAt = startedAt
    }
}
#endif
