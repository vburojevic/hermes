import Foundation

/// Where a chat came from, by the gateway's `source` for its session (`docs/inbox.md` §5,
/// `docs/sessions-and-models.md` §1). The list starts with this app's own chats; the others are
/// one pick away in the filter's Show section.
public enum SessionOrigin: Sendable, Equatable {
    /// Started here, in Hermes Desktop or by another API client: no source, `api_server`,
    /// `desktop` or `hermes_app`.
    case thisApp
    /// A scheduled task's run: `cron`, the source Hermes's scheduler gives every run.
    case scheduled
    /// Everything else: the terminal (`cli`, `tui`), a messaging platform (`telegram`,
    /// `discord`…), an editor (`acp`), the Board's workers (`kanban`) and the rest.
    case otherPlatform

    private static let thisAppSources: Set<String> = ["", "api_server", "desktop", "hermes_app"]

    public init(source: String?) {
        let source = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if Self.thisAppSources.contains(source) {
            self = .thisApp
        } else if source == "cron" {
            self = .scheduled
        } else {
            self = .otherPlatform
        }
    }
}

/// The filter's Show section: which chats the list holds before Unread, Needs You or Running
/// narrow it (`docs/inbox.md` §5).
public enum InboxShow: String, CaseIterable, Sendable {
    case thisApp
    case all
    case otherPlatforms
    case scheduled

    public func includes(_ origin: SessionOrigin) -> Bool {
        switch self {
        case .thisApp: origin == .thisApp
        case .all: true
        case .otherPlatforms: origin == .otherPlatform
        case .scheduled: origin == .scheduled
        }
    }

    /// Whether a chat is in the list under this choice. A chat the person pinned stays in the
    /// default list wherever it came from: pinning is how they keep a chat in sight.
    public func shows(_ origin: SessionOrigin, pinned: Bool) -> Bool {
        includes(origin) || (self == .thisApp && pinned)
    }
}

extension HermesSession {
    public var origin: SessionOrigin { SessionOrigin(source: source) }
}
