import Foundation

/// Changes the person made that are still on their way to the gateway, laid over what the
/// gateway last said. A page shows the change at once and settles it in place (`docs/chat.md`
/// §4a), as the Bots roster's pins and hides do: a list read from before the change doesn't undo
/// it on screen, and a refusal puts the item back as the gateway has it.
///
/// A page keeps the gateway's items and shows `applied(to:)`. When the gateway answers, it takes
/// the answer into its items and calls `settle`; when the gateway refuses, it calls `settle` alone.
/// Only the newest change to an item settles it: two taps on a busy Mac can land in either order.
public struct PendingChanges<Item: Identifiable & Sendable>: Sendable where Item.ID: Sendable {
    public enum Change: Sendable {
        /// An item the gateway hasn't made yet, shown after the gateway's items until it has.
        case insert(Item)
        /// The item as it will be once the gateway has the change.
        case update(Item)
        case remove
    }

    /// One change, so `settle` can tell it from a newer one to the same item.
    public struct Token: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    private struct Entry: Sendable {
        var change: Change
        var token: Token
        /// When an insert began, so new items keep the order they were made in.
        var sequence: Int
    }

    private var entries: [Item.ID: Entry] = [:]
    private var sequence = 0

    public init() {}

    /// Starts a change to the item with `id`, replacing any change still on its way to it.
    @discardableResult
    public mutating func begin(_ change: Change, for id: Item.ID) -> Token {
        let token = Token()
        sequence += 1
        entries[id] = Entry(change: change, token: token, sequence: sequence)
        return token
    }

    /// Ends a change, answered or refused. Returns whether it was the newest change to its item;
    /// an older one leaves the newer change showing.
    @discardableResult
    public mutating func settle(_ token: Token, for id: Item.ID) -> Bool {
        guard entries[id]?.token == token else { return false }
        entries[id] = nil
        return true
    }

    /// Whether `token` is still the newest change to the item.
    public func isNewest(_ token: Token, for id: Item.ID) -> Bool {
        entries[id]?.token == token
    }

    /// Whether a change to the item is still on its way.
    public func isPending(_ id: Item.ID) -> Bool {
        entries[id] != nil
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The item as the change still on its way will leave it (`nil` for a removal, or none).
    public func item(for id: Item.ID) -> Item? {
        switch entries[id]?.change {
        case .insert(let item), .update(let item): item
        case .remove, nil: nil
        }
    }

    /// The gateway's items with every change still on its way: updates in place, removals gone,
    /// new items after the rest in the order they were made.
    public func applied(to items: [Item]) -> [Item] {
        guard !entries.isEmpty else { return items }
        var shown: [Item] = []
        shown.reserveCapacity(items.count)
        var present = Set<Item.ID>()
        for item in items {
            present.insert(item.id)
            switch entries[item.id]?.change {
            case nil: shown.append(item)
            case .remove: continue
            case .update(let changed), .insert(let changed): shown.append(changed)
            }
        }
        let inserts = entries.compactMap { id, entry -> (Int, Item)? in
            guard case .insert(let item) = entry.change, !present.contains(id) else { return nil }
            return (entry.sequence, item)
        }
        shown += inserts.sorted { $0.0 < $1.0 }.map(\.1)
        return shown
    }
}

/// What a page says when the gateway refused a change it had already shown: what was put back,
/// then the gateway's reason.
public struct RefusedChange: Identifiable, Sendable, Equatable {
    public let id = UUID()
    /// "Couldn't pause “Morning briefing”".
    public var title: String
    /// The gateway's reason, then that it's back as it was.
    public var message: String

    public init(_ title: String, error: any Error, undone: Bool = true) {
        self.title = title
        let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        message = undone ? "\(reason) \(String(localized: "It's back as it was."))" : reason
    }

    public init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }
}
