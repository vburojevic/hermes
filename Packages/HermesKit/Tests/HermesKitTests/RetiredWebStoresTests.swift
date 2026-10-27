import Foundation
import Testing
@testable import HermesKit

/// A removed gateway's web data goes at the next launch, never under a live web view
/// (`docs/connecting-and-voice.md` §7): its stores are written down when it's removed, kept across
/// a relaunch, and deleted one at a time once nothing can use them.
@Suite("A removed gateway's web stores go at the next launch")
@MainActor
struct RetiredWebStoresTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "retired-web-stores-\(UUID().uuidString)"))
    }

    /// Records what's deleted, and how many deletions ever ran at once.
    @MainActor
    final class Remover {
        var removed: [UUID] = []
        var running = 0
        var mostAtOnce = 0
        var failing: Set<UUID> = []

        func remove(_ id: UUID) async throws {
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            defer { running -= 1 }
            // Gives another deletion the chance to start, were the sweep not awaiting each one.
            try await Task.sleep(for: .milliseconds(20))
            if failing.contains(id) { throw URLError(.cannotRemoveFile) }
            removed.append(id)
        }
    }

    @Test func removingAGatewayRecordsBothStores() throws {
        let store = RetiredWebStores(defaults: try defaults())
        let preview = UUID(), browser = UUID()
        store.retire([preview, browser])
        #expect(store.pending == [preview, browser])
    }

    @Test func aStoreIsRecordedOnce() throws {
        let store = RetiredWebStores(defaults: try defaults())
        let preview = UUID()
        store.retire([preview])
        store.retire([preview])
        #expect(store.pending == [preview])
    }

    @Test func theListIsKeptAcrossARelaunch() throws {
        let defaults = try defaults()
        let preview = UUID(), browser = UUID()
        RetiredWebStores(defaults: defaults).retire([preview, browser])
        #expect(RetiredWebStores(defaults: defaults).pending == [preview, browser])
    }

    @Test func aStoreLeavesTheListOnlyOnceItsRemovalRan() async throws {
        let defaults = try defaults()
        let store = RetiredWebStores(defaults: defaults)
        let gone = UUID(), stuck = UUID()
        store.retire([gone, stuck])
        let remover = Remover()
        remover.failing = [stuck]
        let removed = await store.sweep(inUse: [], existing: [gone, stuck], remove: remover.remove)
        #expect(removed == [gone])
        #expect(remover.removed == [gone])
        // The one that failed waits for the next launch.
        #expect(RetiredWebStores(defaults: defaults).pending == [stuck])
    }

    @Test func aStoreACurrentGatewayUsesIsNeverRemoved() async throws {
        let store = RetiredWebStores(defaults: try defaults())
        let current = UUID(), retired = UUID()
        store.retire([current, retired])
        let remover = Remover()
        await store.sweep(inUse: [current], existing: [current, retired], remove: remover.remove)
        #expect(remover.removed == [retired])
        #expect(store.pending.isEmpty)
    }

    @Test func aStoreWebKitDoesNotHaveLeavesTheListUntouched() async throws {
        let store = RetiredWebStores(defaults: try defaults())
        let neverMade = UUID()
        store.retire([neverMade])
        let remover = Remover()
        await store.sweep(inUse: [], existing: [], remove: remover.remove)
        #expect(remover.removed.isEmpty)
        #expect(store.pending.isEmpty)
    }

    @Test func theStoresAreRemovedOneAtATime() async throws {
        let store = RetiredWebStores(defaults: try defaults())
        let preview = UUID(), browser = UUID()
        store.retire([preview, browser])
        let remover = Remover()
        await store.sweep(inUse: [], existing: [preview, browser], remove: remover.remove)
        #expect(remover.removed == [preview, browser])
        #expect(remover.mostAtOnce == 1)
    }

    @Test func aSweepWhileOneRunsLeavesItAlone() async throws {
        let store = RetiredWebStores(defaults: try defaults())
        let preview = UUID(), browser = UUID()
        store.retire([preview, browser])
        let remover = Remover()
        let first = Task { await store.sweep(inUse: [], existing: [preview, browser], remove: remover.remove) }
        let second = Task { await store.sweep(inUse: [], existing: [preview, browser], remove: remover.remove) }
        let removed = await first.value + second.value
        #expect(removed.sorted { $0.uuidString < $1.uuidString } == [preview, browser].sorted { $0.uuidString < $1.uuidString })
        #expect(remover.removed.count == 2)
        #expect(remover.mostAtOnce == 1)
    }

    @Test func aGatewayRemovedDuringASweepStaysForTheNextLaunch() async throws {
        let store = RetiredWebStores(defaults: try defaults())
        let first = UUID(), later = UUID()
        store.retire([first])
        let remover = Remover()
        await store.sweep(inUse: [], existing: [first, later]) { id in
            store.retire([later])
            try await remover.remove(id)
        }
        #expect(remover.removed == [first])
        #expect(store.pending == [later])
    }
}
