import Foundation
import HermesPush

/// Where tapping a notice (a push on the iPhone and iPad, the Mac's own notification) takes you,
/// `docs/notifications.md` §3. The chat a notice names decides, never its profile: a profile says
/// which Hermes profile ran the turn, which for a gateway that itself runs under a profile is every
/// chat it has, so only a chat known to be a Bot's own opens the Bot.
public enum NoticeDestination: Equatable, Sendable {
    case card(String, board: String?, projectID: String?)
    /// A tidy's report, for the Bot that tidied (nil for the primary Bot).
    case tidying(bot: String?)
    case room(String)
    case tasks
    /// The Bot's own chat, by profile.
    case bot(String)
    /// A chat by its list key (`HermesSession.stableID`), or by the notice's id when the list
    /// doesn't hold it yet.
    case chat(String)
}

public struct NoticeRouting: Sendable {
    /// Each Bot's own chats: session id → profile (`BotRoster.botChats`, or the copy shared with
    /// the extension).
    public var botChats: [String: String]
    /// Every listed chat's id and stable id → its stable id.
    public var chatKeys: [String: String]

    public init(botChats: [String: String] = [:], chatKeys: [String: String] = [:]) {
        self.botChats = botChats
        self.chatKeys = chatKeys
    }

    /// The chat a notice opens by, when where it goes depends on the Bots and the chat list (a
    /// cold launch waits for both before deciding). Cards, tidying, rooms and tasks don't.
    public static func chat(of notice: PushNotice) -> String? {
        if notice.kind.isCard && notice.cardID != nil { return nil }
        if notice.kind == .tidied || notice.roomID != nil || notice.kind == .task || notice.kind == .taskFailed {
            return nil
        }
        return notice.chatID
    }

    public func destination(for notice: PushNotice) -> NoticeDestination? {
        if notice.kind.isCard, let card = notice.cardID {
            return .card(card, board: notice.board, projectID: notice.projectID)
        }
        if notice.kind == .tidied { return .tidying(bot: notice.profile) }
        if let room = notice.roomID { return .room(room) }
        if notice.kind == .task || notice.kind == .taskFailed { return .tasks }
        guard let chat = notice.chatID else {
            // A Bot's reply with no chat named is from its own chat.
            return notice.profile.map(NoticeDestination.bot)
        }
        if let bot = botChats[chat] { return .bot(bot) }
        if let key = chatKeys[chat] { return .chat(key) }
        // A chat the list doesn't hold yet (started on another device since it loaded, or older than
        // its first page) opens by its id. Its profile doesn't make it a Bot's: on a gateway that runs
        // under a profile every chat carries one, and the gateway can't say which profile it is.
        return .chat(chat)
    }
}
