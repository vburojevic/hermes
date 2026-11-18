import Foundation
import HermesPush

/// The chats on screen: the one open on each gateway a visible window shows (`docs/notifications.md`
/// §1.2, §1.6). Each Mac window and iPad scene keeps its own gateway, so two windows can show two
/// chats on two gateways, and both count as seen. Windows on the same gateway share its open chat.
public struct VisibleChats: Equatable, Sendable {
    /// Per gateway on screen: every id a notice might name its open chat by, the session id first.
    private let chats: [UUID: [String]]

    /// Nothing on screen: the app is away.
    public static let none = VisibleChats(chats: [:])

    private init(chats: [UUID: [String]]) {
        self.chats = chats
    }

    /// - Parameters:
    ///   - isActive: the app is in front. Away, nothing is on screen whatever the windows show.
    ///   - gateways: the gateways visible windows show (`WindowGateways.visibleGateways`).
    ///   - openChat: a gateway's open chat, as every id a notice might name it by (the session id
    ///     first), or nothing when no chat is open there.
    public init(isActive: Bool, gateways: Set<UUID>, openChat: (UUID) -> [String]) {
        guard isActive else {
            self.init(chats: [:])
            return
        }
        var chats: [UUID: [String]] = [:]
        for gateway in gateways {
            let ids = openChat(gateway).filter { !$0.isEmpty }
            if !ids.isEmpty { chats[gateway] = ids }
        }
        self.init(chats: chats)
    }

    /// The ids of the chat open on a gateway, the session id first: what its presence names.
    public func ids(on gateway: UUID) -> [String] {
        chats[gateway] ?? []
    }

    /// The gateway that shows the chat, group chat or thread a notice is about, or nil when no
    /// visible window does. A notice whose gateway the app doesn't know (`gateway` nil) matches the
    /// chat open on any gateway on screen.
    public func gateway(showing notice: PushNotice, on gateway: UUID?) -> UUID? {
        let named = [notice.chatID, notice.roomID, notice.thread].compactMap(\.self).filter { !$0.isEmpty }
        guard !named.isEmpty else { return nil }
        let candidates = gateway.map { [$0] } ?? chats.keys.sorted { $0.uuidString < $1.uuidString }
        return candidates.first { id in
            let open = Set(chats[id] ?? [])
            return named.contains(where: open.contains)
        }
    }

    /// Whether a notice is about a chat on screen: no banner for it (`docs/notifications.md` §2).
    public func isShowing(_ notice: PushNotice, on gateway: UUID?) -> Bool {
        self.gateway(showing: notice, on: gateway) != nil
    }
}
