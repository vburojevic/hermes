import Foundation
@testable import HermesKit
import Testing

/// A scheduled task's runs aren't chats (`docs/inbox.md` §5, `docs/tasks.md` §5): runs with
/// output show under Show → Scheduled Tasks and with their task, empty ones nowhere. The rows are
/// shaped like Hermes's: `source` `cron`, no title, a `cron_<job>_<time>` or `local-…` id.
@Suite("Scheduled runs")
struct ScheduledRunTests {
    private func run(_ id: String, messages: Int?) -> HermesSession {
        HermesSession(id: id, source: "cron", messageCount: messages)
    }

    private let chat = HermesSession(id: "chat-1")
    private let telegram = HermesSession(id: "tg-1", source: "telegram", messageCount: 4)

    /// The source decides, whatever shape the id has.
    @Test func aRunIsKnownByItsSource() {
        #expect(run("cron_9f2c_20261114_080000", messages: 2).isScheduledRun)
        #expect(run("local-7d1e", messages: 2).isScheduledRun)
        #expect(!HermesSession(id: "cron_looks_like_one", source: "api_server").isScheduledRun)
        #expect(!telegram.isScheduledRun)
    }

    /// Empty means Hermes said no messages; a row without a count isn't taken for empty.
    @Test func anEmptyRunHasNoMessages() {
        #expect(run("cron_a_20261114_080000", messages: 0).isEmptyScheduledRun)
        #expect(!run("cron_a_20261114_081000", messages: 3).isEmptyScheduledRun)
        #expect(!run("cron_a_20261114_082000", messages: nil).isEmptyScheduledRun)
        #expect(!HermesSession(id: "new-chat", messageCount: 0).isEmptyScheduledRun)
    }

    /// The app keeps everything but empty runs, and its chats are everything but runs.
    @Test func theListKeepsRunsWithOutputApartFromChats() {
        let empty = run("cron_a_20261114_080000", messages: 0)
        let full = run("cron_a_20261114_081000", messages: 2)
        let page = [chat, empty, telegram, full]
        #expect(ScheduledRuns.kept(page).map(\.id) == ["chat-1", "tg-1", "cron_a_20261114_081000"])
        #expect(ScheduledRuns.chats(ScheduledRuns.kept(page)).map(\.id) == ["chat-1", "tg-1"])
    }

    /// Scheduled Tasks holds the runs with output and nothing else; every other choice leaves
    /// runs out, pinned or not.
    @Test func runsShowOnlyUnderScheduledTasks() {
        let empty = run("cron_a_20261114_080000", messages: 0)
        let full = run("cron_a_20261114_081000", messages: 2)
        var pinned = run("cron_a_20261114_082000", messages: 2)
        pinned.pinned = true
        let all = [chat, telegram, empty, full, pinned]
        #expect(all.filter(InboxShow.scheduled.shows).map(\.id) == ["cron_a_20261114_081000", "cron_a_20261114_082000"])
        #expect(all.filter(InboxShow.thisApp.shows).map(\.id) == ["chat-1"])
        #expect(all.filter(InboxShow.all.shows).map(\.id) == ["chat-1", "tg-1"])
        #expect(all.filter(InboxShow.otherPlatforms.shows).map(\.id) == ["tg-1"])
    }

    /// Hermes's run rows (`GET /api/cron/jobs/{id}/runs`) carry the chat's message count.
    @Test func aRunReadsItsMessageCount() throws {
        let json = try #require(JSONValue.parse(#"{"id": "cron_a_20261114_080000", "source": "cron", "message_count": 0, "started_at": 1794643200}"#))
        #expect(CronRun(json: json).messageCount == 0)
        #expect(CronRun(json: json).isEmpty)
    }

    /// A task's runs: newest first, without the ones that left nothing. A failed run or a
    /// script's output still shows, and so does a run whose count Hermes didn't give.
    @Test func aTasksRunsLeaveOutTheEmptyOnes() {
        let start = Date(timeIntervalSince1970: 1_794_643_200)
        let runs = [
            CronRun(sessionID: "cron_a_1", startedAt: start, messageCount: 0),
            CronRun(sessionID: "cron_a_2", startedAt: start + 600, summary: "Two new invoices", messageCount: 4),
            CronRun(sessionID: "cron_a_3", startedAt: start + 1200, failed: true, error: "Provider timed out", messageCount: 0),
            CronRun(sessionID: nil, startedAt: start + 1800, summary: "disk 81% full"),
            CronRun(sessionID: "cron_a_5", startedAt: start + 2400, messageCount: 0),
            CronRun(sessionID: "cron_a_6", startedAt: start + 3000),
        ]
        #expect(ScheduledRuns.shown(runs).map(\.id) == ["cron_a_6", "\(start.timeIntervalSince1970 + 1800)", "cron_a_3", "cron_a_2"])
    }

    /// Hermes titles each finished run after its task, so a task's name finds its empty runs by
    /// title; Tasks search shows only the runs with something in them.
    @Test func searchLeavesOutTheEmptyRuns() {
        let results = [
            SessionSearchResult(sessionID: "cron_a_20261114_080000", title: "Watch the inbox #12", source: "cron", messageCount: 0),
            SessionSearchResult(sessionID: "cron_a_20261114_081000", title: "Watch the inbox #13", source: "cron", messageCount: 2),
            SessionSearchResult(sessionID: "cron_a_20261114_082000", snippet: ">>>inbox<<< is quiet", role: "assistant",
                                source: "cron"),
            SessionSearchResult(sessionID: "chat-1", title: "Inbox rules", source: "api_server", messageCount: 0),
        ]
        #expect(ScheduledRuns.shown(results).map(\.sessionID)
            == ["cron_a_20261114_081000", "cron_a_20261114_082000", "chat-1"])
    }

    /// A run opens as a chat only from the gateway's own profile; a Bot's routine keeps its runs
    /// in the Bot's profile, so they read in place (`docs/tasks.md` §5).
    @Test func onlyTheGatewaysOwnRunsOpenAsChats() throws {
        let json = try #require(JSONValue.parse(#"{"id": "cron_d_20261114_080000", "source": "cron", "profile": "researcher", "started_at": 1794643200}"#))
        let botRun = CronRun(json: json)
        #expect(botRun.profile == "researcher")
        #expect(!botRun.opensAsChat(gatewayProfile: nil))
        #expect(botRun.opensAsChat(gatewayProfile: "researcher"))
        #expect(CronRun(sessionID: "cron_a_1", startedAt: nil, profile: "default").opensAsChat(gatewayProfile: nil))
        #expect(CronRun(sessionID: "cron_a_1", startedAt: nil).opensAsChat(gatewayProfile: "work"))
        #expect(!CronRun(sessionID: nil, startedAt: nil, summary: "disk 81% full").opensAsChat(gatewayProfile: nil))
    }

    /// Past runs: every routine's runs in one list, newest first, each named by its routine,
    /// without the empty ones.
    @Test func pastRunsMergeEveryRoutineNewestFirst() {
        let start = Date(timeIntervalSince1970: 1_794_643_200)
        let digest = [
            CronRun(sessionID: "cron_d_1", startedAt: start, summary: "Three papers", messageCount: 2),
            CronRun(sessionID: "cron_d_2", startedAt: start + 7200, messageCount: 0),
        ]
        let watch = [CronRun(sessionID: "cron_w_1", startedAt: start + 3600, failed: true, error: "Feed timed out")]
        let merged = ScheduledRuns.merged([(routine: "Daily digest", runs: digest), (routine: "Watch the feed", runs: watch)])
        #expect(merged.map(\.id) == ["cron_w_1", "cron_d_1"])
        #expect(merged.map(\.routine) == ["Watch the feed", "Daily digest"])
    }

    /// A run's row carries only a short preview; the whole reply is the transcript's last answer.
    @Test func aRunsReplyIsItsLastAnswer() {
        let transcript = SessionTranscript(sessionID: "cron_d_1", messages: [
            SessionMessage(id: 1, role: "user", content: .text("Summarize the new papers")),
            SessionMessage(id: 2, role: "assistant", content: .text("Looking.")),
            SessionMessage(id: 3, role: "tool", content: .text("{}")),
            SessionMessage(id: 4, role: "assistant", content: .text("  Three new papers on speculative decoding.\n")),
            SessionMessage(id: 5, role: "assistant", content: .text(" ")),
        ])
        #expect(ScheduledRuns.reply(in: transcript) == "Three new papers on speculative decoding.")
        #expect(ScheduledRuns.reply(in: SessionTranscript(sessionID: "s", messages: [])) == nil)
    }
}
