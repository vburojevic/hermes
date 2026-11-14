import Foundation
@testable import HermesKit
import Testing

/// The list starts with this app's chats; other platforms and scheduled runs are a filter away
/// (`docs/inbox.md` §5). The sources are the ones Hermes Agent writes: the gateway's platforms
/// (`gateway/config.py`), the scheduler's `cron`, the terminal's `cli` and `tui`, and the rest.
@Suite("Session origin")
struct SessionOriginTests {
    @Test(arguments: [nil, "", "api_server", "desktop", "hermes_app", " API_SERVER "])
    func thisAppsOwnChats(source: String?) {
        #expect(SessionOrigin(source: source) == .thisApp)
    }

    @Test(arguments: ["cron", "Cron"])
    func scheduledRuns(source: String) {
        #expect(SessionOrigin(source: source) == .scheduled)
    }

    @Test(arguments: [
        "cli", "tui", "telegram", "discord", "whatsapp", "slack", "signal", "matrix", "email", "sms",
        "acp", "kanban", "webhook", "local", "subagent", "bot_room", "a_platform_from_next_year",
    ])
    func otherPlatforms(source: String) {
        #expect(SessionOrigin(source: source) == .otherPlatform)
    }

    /// A session reads its own origin, so a cron run's id shape doesn't matter, only its source.
    @Test func aSessionKnowsWhereItCameFrom() {
        #expect(HermesSession(id: "a").origin == .thisApp)
        #expect(HermesSession(id: "b", source: nil).origin == .thisApp)
        #expect(HermesSession(id: "cron_9f2c_20261114_080000", source: "cron").origin == .scheduled)
        #expect(HermesSession(id: "c", source: "telegram").origin == .otherPlatform)
    }

    /// Show picks one origin, or every one with All Chats.
    @Test func showIncludesItsOwnOrigin() {
        let origins: [SessionOrigin] = [.thisApp, .otherPlatform, .scheduled]
        #expect(origins.filter(InboxShow.thisApp.includes) == [.thisApp])
        #expect(origins.filter(InboxShow.all.includes) == origins)
        #expect(origins.filter(InboxShow.otherPlatforms.includes) == [.otherPlatform])
        #expect(origins.filter(InboxShow.scheduled.includes) == [.scheduled])
    }

    /// A pinned chat stays in the default list wherever it came from; the narrowed choices
    /// still show only their own origin.
    @Test func pinnedChatsStayInTheDefaultList() {
        #expect(InboxShow.thisApp.shows(.otherPlatform, pinned: true))
        #expect(InboxShow.thisApp.shows(.scheduled, pinned: true))
        #expect(!InboxShow.thisApp.shows(.otherPlatform, pinned: false))
        #expect(!InboxShow.scheduled.shows(.otherPlatform, pinned: true))
        #expect(!InboxShow.otherPlatforms.shows(.thisApp, pinned: true))
        #expect(InboxShow.all.shows(.scheduled, pinned: false))
    }
}
