import Foundation

/// What the app shows waiting on the person in one gateway, for the badge (`docs/notifications.md` §2
/// Badge): every request on a chat's card or in its Needs You dock, and one for each chat or group chat
/// whose row says it waits on the person while the app holds none of its requests. In front, a gateway's
/// open requests count no higher than this (`PushShared.recordShown`), so a request the plugin kept for a
/// turn that had ended can't hold the icon at 1 with nothing to answer (#86).
public enum ShownRequests {
    /// `cards`: the waiting items' ids (`WaitingItem.id`) by chat key; `waiting`: the keys of chats whose
    /// row waits on the person.
    public static func count(cards: [String: [String]], waiting: Set<String>) -> Int {
        let ids = Set(cards.values.joined())
        let held = Set(cards.filter { !$0.value.isEmpty }.keys)
        return ids.count + waiting.subtracting(held).count
    }
}
