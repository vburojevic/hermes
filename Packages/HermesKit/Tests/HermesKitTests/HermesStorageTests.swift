import Foundation
import Testing
@testable import HermesKit

/// Where the app's queues and caches live, and how the release Mac app carries its own items over
/// from the shared folders (`StorageLayout`). Everything runs in a temporary folder.
@Suite("Storage layout")
struct HermesStorageTests {
    private static let dev = "co.caffeinatedcode.hermes.dev"

    private final class Home {
        let url = FileManager.default.temporaryDirectory.appending(path: "hermes-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        var support: URL { url.appending(path: "Application Support", directoryHint: .isDirectory) }
        var caches: URL { url.appending(path: "Caches", directoryHint: .isDirectory) }

        func layout(bundle: String?, isMac: Bool = true) -> StorageLayout {
            StorageLayout(applicationSupport: support, caches: caches, bundleIdentifier: bundle, isMac: isMac)
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// Only a folder holding a `queue.json` counts as ours here, as the app's own check does.
    private static func hasQueue(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "queue.json").path(percentEncoded: false))
    }

    @Test func onTheMacEachBuildKeepsItsFilesInAFolderNamedByItsBundleID() {
        let home = Home()
        let release = home.layout(bundle: HermesStorage.releaseBundleIdentifier)
        #expect(release.supportRoot == home.support.appending(path: HermesStorage.releaseBundleIdentifier, directoryHint: .isDirectory))
        #expect(release.cachesRoot == home.caches.appending(path: HermesStorage.releaseBundleIdentifier, directoryHint: .isDirectory))
        let debug = home.layout(bundle: Self.dev)
        #expect(debug.supportRoot == home.support.appending(path: Self.dev, directoryHint: .isDirectory))
        #expect(debug.cachesRoot == home.caches.appending(path: Self.dev, directoryHint: .isDirectory))
        #expect(debug.supportRoot != release.supportRoot)
    }

    @Test func onIOSTheFilesStayStraightInTheSystemFolders() {
        let home = Home()
        let layout = home.layout(bundle: HermesStorage.releaseBundleIdentifier, isMac: false)
        #expect(layout.supportRoot == home.support)
        #expect(layout.cachesRoot == home.caches)
        #expect(!layout.carriesLegacyItemsOver)
    }

    @Test func theReleaseAppMovesOnlyTheItemItReadsWithItsAttachments() throws {
        let home = Home()
        let layout = home.layout(bundle: HermesStorage.releaseBundleIdentifier)
        let legacy = home.support.appending(path: "Outbox/chat-a", directoryHint: .isDirectory)
        try home.write("[]", to: legacy.appending(path: "queue.json"))
        try home.write("voice", to: legacy.appending(path: "1.blob"))
        let other = home.support.appending(path: "Outbox/chat-b/queue.json")
        try home.write("[]", to: other)
        let waiting = home.support.appending(path: "WaitingChats/g.json")
        try home.write("[]", to: waiting)

        let folder = layout.itemToRead("Outbox/chat-a", isDirectory: true, isOurs: Self.hasQueue)

        #expect(folder == layout.supportRoot.appending(path: "Outbox/chat-a", directoryHint: .isDirectory))
        #expect(home.exists(folder.appending(path: "queue.json")))
        #expect(try String(contentsOf: folder.appending(path: "1.blob"), encoding: .utf8) == "voice")
        #expect(!home.exists(legacy))
        // Nothing else in the shared folder moved.
        #expect(home.exists(other))
        #expect(home.exists(waiting))
    }

    @Test func aFileMovesTheSameWay() throws {
        let home = Home()
        let layout = home.layout(bundle: HermesStorage.releaseBundleIdentifier)
        let legacy = home.support.appending(path: "WaitingChats/g.json")
        try home.write("[1]", to: legacy)
        let file = layout.itemToRead("WaitingChats/g.json", isDirectory: false) { _ in true }
        #expect(try String(contentsOf: file, encoding: .utf8) == "[1]")
        #expect(!home.exists(legacy))
    }

    @Test func hermesDevNeverMovesAnything() throws {
        let home = Home()
        let layout = home.layout(bundle: Self.dev)
        let legacy = home.support.appending(path: "Outbox/chat-a/queue.json")
        try home.write("[]", to: legacy)
        let folder = layout.itemToRead("Outbox/chat-a", isDirectory: true, isOurs: Self.hasQueue)
        #expect(folder == layout.supportRoot.appending(path: "Outbox/chat-a", directoryHint: .isDirectory))
        #expect(!home.exists(folder))
        #expect(home.exists(legacy))
        #expect(!layout.carriesLegacyItemsOver)
    }

    @Test func aSecondReadMovesNothingAgain() throws {
        let home = Home()
        let layout = home.layout(bundle: HermesStorage.releaseBundleIdentifier)
        try home.write("[]", to: home.support.appending(path: "FollowUpQueues/chat-a/queue.json"))
        let folder = layout.itemToRead("FollowUpQueues/chat-a", isDirectory: true, isOurs: Self.hasQueue)
        // An older build writes the shared folder again; the release app's own copy stays its own.
        let stale = home.support.appending(path: "FollowUpQueues/chat-a/queue.json")
        try home.write("[\"stale\"]", to: stale)
        try home.write("[\"own\"]", to: folder.appending(path: "queue.json"))
        let again = layout.itemToRead("FollowUpQueues/chat-a", isDirectory: true, isOurs: Self.hasQueue)
        #expect(again == folder)
        #expect(try String(contentsOf: folder.appending(path: "queue.json"), encoding: .utf8) == "[\"own\"]")
        #expect(home.exists(stale))
    }

    @Test func anItemThatIsNotOursStaysWhereItIs() throws {
        let home = Home()
        let layout = home.layout(bundle: HermesStorage.releaseBundleIdentifier)
        let foreign = home.support.appending(path: "Outbox/chat-a/mail.db")
        try home.write("someone else's", to: foreign)
        let folder = layout.itemToRead("Outbox/chat-a", isDirectory: true, isOurs: Self.hasQueue)
        #expect(!home.exists(folder))
        #expect(home.exists(foreign))
    }
}
