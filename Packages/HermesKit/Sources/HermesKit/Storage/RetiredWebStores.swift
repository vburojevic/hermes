import Foundation

/// The web data stores of gateways removed from this device, waiting to be deleted
/// (`docs/connecting-and-voice.md` §7). WebKit deletes a store safely only once no web view uses it,
/// and deleting one under a live web view crashed the app, so a removed gateway's stores (its
/// Preview's and its in-app browser's) are written down here and deleted at the next launch, before
/// any web view is made, one at a time.
@MainActor
public final class RetiredWebStores {
    private let defaults: UserDefaults
    /// One sweep at a time: the next waits until this one has ended.
    private var sweeping = false

    static let key = "webStores.retired"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stores waiting, oldest first.
    public var pending: [UUID] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// A gateway was removed: its stores wait for the next launch.
    public func retire(_ ids: [UUID]) {
        var list = pending
        for id in ids where !list.contains(id) { list.append(id) }
        save(list)
    }

    /// Deletes the waiting stores one after another, each awaited before the next starts.
    /// - Parameters:
    ///   - inUse: the stores the current gateways use. They're never deleted, and they leave the
    ///     list: they belong to a gateway that's here.
    ///   - existing: the stores WebKit has (`allDataStoreIdentifiers`). One it doesn't have leaves
    ///     the list with nothing to delete.
    ///   - remove: deletes one store. One that fails waits for the next launch.
    /// - Returns: the stores deleted.
    @discardableResult
    public func sweep(inUse: Set<UUID>, existing: Set<UUID>, remove: (UUID) async throws -> Void) async -> [UUID] {
        guard !sweeping else { return [] }
        sweeping = true
        defer { sweeping = false }
        var removed: [UUID] = []
        for id in pending {
            if inUse.contains(id) || !existing.contains(id) {
                forget(id)
                continue
            }
            guard (try? await remove(id)) != nil else { continue }
            forget(id)
            removed.append(id)
        }
        return removed
    }

    /// Re-read each time: a gateway removed while a sweep runs adds to the list meanwhile.
    private func forget(_ id: UUID) {
        save(pending.filter { $0 != id })
    }

    private func save(_ list: [UUID]) {
        if list.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(list.map(\.uuidString), forKey: Self.key)
        }
    }
}
