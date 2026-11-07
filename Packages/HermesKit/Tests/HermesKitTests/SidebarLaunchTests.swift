import Foundation
import Testing
@testable import HermesKit

@Suite("Sidebar launch")
struct SidebarLaunchTests {
    private static let base = Date(timeIntervalSince1970: 1_760_600_000)

    private static func chats(_ count: Int) -> [HermesSession] {
        (0..<count).map { n in
            var chat = HermesSession(id: "chat-\(n)", preview: "Question \(n)")
            chat.title = n.isMultiple(of: 3) ? "Chat \(n)" : nil
            chat.lastActive = base.addingTimeInterval(-Double(n) * 60)
            chat.pinned = n == 4
            return chat
        }
    }

    private static func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "chat-list-\(UUID().uuidString).json")
    }

    @Test func keptListReadsBackAsItWas() throws {
        let kept = Self.chats(12)
        let url = Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(ChatListSnapshot.encode(kept)).write(to: url)

        let read = try #require(ChatListSnapshot.read(url))
        #expect(read.map(\.id) == kept.map(\.id))
        #expect(read.map(\.title) == kept.map(\.title))
        #expect(read.map(\.preview) == kept.map(\.preview))
        #expect(read.map(\.pinned) == kept.map(\.pinned))
        #expect(read.map(\.lastActive) == kept.map(\.lastActive))
    }

    @Test func keepsOnlyTheNewestPage() throws {
        let url = Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(ChatListSnapshot.encode(Self.chats(260))).write(to: url)

        let read = try #require(ChatListSnapshot.read(url))
        #expect(read.count == ChatListSnapshot.maxRows)
        #expect(read.first?.id == "chat-0")
        #expect(read.last?.id == "chat-\(ChatListSnapshot.maxRows - 1)")
    }

    @Test func nothingToKeepWritesNothing() {
        #expect(ChatListSnapshot.encode([]) == nil)
    }

    @Test func missingOrBrokenFileFallsBackToTheGateway() throws {
        let missing = Self.file()
        #expect(ChatListSnapshot.read(missing) == nil)

        let broken = Self.file()
        defer { try? FileManager.default.removeItem(at: broken) }
        try Data("{\"not\": \"a list\"".utf8).write(to: broken)
        #expect(ChatListSnapshot.read(broken) == nil)

        let empty = Self.file()
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data("[]".utf8).write(to: empty)
        #expect(ChatListSnapshot.read(empty) == nil)
    }

    /// The first frame lists the newest screenful in order; after it, every row, even a short list.
    @Test func firstFrameListsOneScreenful() {
        let rows = Self.chats(ChatListSnapshot.maxRows)
        let first = ChatListSnapshot.listed(rows, firstFrame: true)
        #expect(first.map(\.id) == rows.prefix(ChatListSnapshot.firstFrameRows).map(\.id))
        #expect(ChatListSnapshot.listed(rows, firstFrame: false).map(\.id) == rows.map(\.id))

        let few = Self.chats(5)
        #expect(ChatListSnapshot.listed(few, firstFrame: true).map(\.id) == few.map(\.id))
        #expect(ChatListSnapshot.listed([HermesSession](), firstFrame: true).isEmpty)
    }

    /// The launch reads the file on the main thread before the first frame, so a full page has to
    /// stay a few milliseconds' work even in a debug build.
    @Test func fullPageReadsQuickly() throws {
        let url = Self.file()
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(ChatListSnapshot.encode(Self.chats(ChatListSnapshot.maxRows))).write(to: url)

        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = ChatListSnapshot.read(url) }
        #expect(elapsed < .milliseconds(100))
    }
}
