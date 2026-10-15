import Foundation

/// Settings → Notifications (`docs/notifications.md` §5). The gateway decides what to send, so
/// these sync to every registered gateway (the plugin's `preferences` command); `showDetails`
/// is applied on the device.
public struct PushPreferences: Codable, Sendable, Hashable {
    public enum Tasks: String, Codable, Sendable, CaseIterable {
        case all, failures, off
    }

    public enum Bots: String, Codable, Sendable, CaseIterable {
        case all, mentions, off
    }

    public enum ShowDetails: String, Codable, Sendable, CaseIterable {
        case always, unlocked, never
    }

    /// Approvals and questions.
    public var approvals = true
    /// Sudo, secrets and sign-ins.
    public var passwords = true
    public var replies = true
    /// Seconds a turn must run before its reply notifies.
    public var replyAfter = 30
    public var tasks = Tasks.all
    public var bots = Bots.mentions
    public var background = true
    public var liveActivity = true
    /// `never` keeps every notification to its kind ("Reply ready on Home Server"). `always` and
    /// `unlocked` (older builds' default) both carry the text; the Lock Screen hides it until
    /// unlock when iPhone's Show Previews says When Unlocked.
    public var showDetails = ShowDetails.always
    /// Settings → Notifications → Show Message Text.
    public var showsText: Bool {
        get { showDetails != .never }
        set { showDetails = newValue ? .always : .never }
    }
    /// How the person is @mentioned in group chats.
    public var mentionNames: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case approvals, passwords, replies, tasks, bots, background
        case replyAfter = "reply_after"
        case liveActivity = "live_activity"
        case showDetails = "show_details"
        case mentionNames = "mention_names"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PushPreferences()
        approvals = try c.decodeIfPresent(Bool.self, forKey: .approvals) ?? defaults.approvals
        passwords = try c.decodeIfPresent(Bool.self, forKey: .passwords) ?? defaults.passwords
        replies = try c.decodeIfPresent(Bool.self, forKey: .replies) ?? defaults.replies
        replyAfter = try c.decodeIfPresent(Int.self, forKey: .replyAfter) ?? defaults.replyAfter
        tasks = (try? c.decodeIfPresent(Tasks.self, forKey: .tasks)) ?? defaults.tasks
        bots = (try? c.decodeIfPresent(Bots.self, forKey: .bots)) ?? defaults.bots
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? defaults.background
        liveActivity = try c.decodeIfPresent(Bool.self, forKey: .liveActivity) ?? defaults.liveActivity
        showDetails = (try? c.decodeIfPresent(ShowDetails.self, forKey: .showDetails)) ?? defaults.showDetails
        mentionNames = try c.decodeIfPresent([String].self, forKey: .mentionNames) ?? []
    }
}
