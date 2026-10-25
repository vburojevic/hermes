import Foundation
import Testing
@testable import HermesKit

@Suite("Search")
struct SessionSearchTests {
    @Test func markersBecomeHighlightsAndNeverShow() {
        let runs = SnippetRun.parse("…the socket now >>>reconnect<<<s with backoff when the Mac >>>wakes<<<")
        #expect(runs == [
            SnippetRun(text: "…the socket now ", isMatch: false), SnippetRun(text: "reconnect", isMatch: true),
            SnippetRun(text: "s with backoff when the Mac ", isMatch: false), SnippetRun(text: "wakes", isMatch: true),
        ])
        // Unbalanced or stray markers are dropped, never drawn.
        #expect(SnippetRun.plain("a >>>b c") == "a b c" && SnippetRun.parse("a >>>b c").last?.isMatch == true)
        #expect(SnippetRun.plain("x <<< y >>>z<<< >>>") == "x  y z ")
        #expect(!SnippetRun.plain(">>>>>><<<<<<").contains(">>>") && !SnippetRun.plain("a<<<b").contains("<<<"))
    }

    @Test func resultsReadEveryField() throws {
        let json = JSONValue.parse(#"""
        {"session_id": "s_tip", "lineage_root": "s_root", "title": "Fix the reconnect after sleep", "preview": "Fix the",
         "snippet": "…the socket now >>>reconnect<<<s", "role": "assistant", "source": "api_server", "model": "claude",
         "session_started": 1760531400.5, "last_active": null, "message_count": 12, "archived": false, "profile": "default"}
        """#)
        let result = try #require(json.flatMap(SessionSearchResult.init(json:)))
        #expect(result.sessionID == "s_tip" && result.lineageRoot == "s_root" && result.role == "assistant")
        #expect(result.time(row: nil) == Date(timeIntervalSince1970: 1760531400.5) && result.lastActive == nil)
        #expect(result.matchedWords == ["reconnect"] && !result.isTaskRun)
        let task = try #require(JSONValue.parse(#"{"id": "cron_1", "source": "cron", "snippet": "x"}"#).flatMap(SessionSearchResult.init(json:)))
        #expect(task.isTaskRun && task.sessionID == "cron_1")
    }

    @Test func aResultsTimeIsItsRowsNotHermesActivity() {
        let now = Date(timeIntervalSince1970: 1_760_600_000)
        // Last spoken in yesterday; a heartbeat (or a compaction) 7 minutes ago moved `last_active`.
        let line = LastLine(speaker: .hermes, text: "nvm loads lazily now.", at: now.addingTimeInterval(-86_400))
        let started = now.addingTimeInterval(-90_000)
        let titleHit = SessionSearchResult(sessionID: "s1", title: "zsh startup time", snippet: "zsh startup time",
                                           sessionStarted: started, lastActive: now.addingTimeInterval(-420))
        // A chat the list has: its row's time, so it never reads "7 min".
        let row = RowTime.of(line: line, activity: titleHit.lastActive, created: started)
        #expect(titleHit.time(row: row) == line.at)
        // One the app doesn't list: when it started, never the activity.
        #expect(titleHit.time(row: nil) == started)
        // Sorted by the time they show.
        let older = SessionSearchResult(sessionID: "s2", sessionStarted: now.addingTimeInterval(-3 * 86_400),
                                        lastActive: now.addingTimeInterval(-60))
        let fresh = SessionSearchResult(sessionID: "s3", sessionStarted: now.addingTimeInterval(-3600), lastActive: nil)
        let times = ["s1": titleHit.time(row: row), "s2": older.time(row: nil), "s3": fresh.time(row: nil)]
        #expect(RowTime.ordered([older, titleHit, fresh], pinned: { _ in false }) { times[$0.sessionID] ?? nil }
            .map(\.sessionID) == ["s3", "s1", "s2"])
    }

    @Test func offlineMatchesTitlesOnly() {
        var a = HermesSession(id: "a")
        a.title = "Fix the reconnect after sleep"
        var b = HermesSession(id: "b")
        b.title = "Release notes draft"
        b.preview = "reconnect" // previews aren't searched when there's a title
        let found = SessionSearch.titleMatches("reconn", in: [a, b])
        #expect(found.map(\.id) == ["a"])
        #expect(SessionSearch.titleMatches("release DRAFT", in: [a, b]).map(\.id) == ["b"])
        #expect(SessionSearch.titleMatches("  ", in: [a, b]).isEmpty)
    }
}

@Suite("Search landing")
struct SearchLandingTests {
    @Test func landsOnTheMessageWithTheSnippet() {
        let result = SessionSearchResult(sessionID: "s", snippet: "…the socket now >>>reconnects<<< with backoff when")
        let focus = SearchFocus(result: result)
        #expect(focus.words == ["reconnects"] && focus.phrase == "socket now reconnects with backoff")
        let items: [TranscriptItem] = [
            .user(UserEntry(id: "u1", text: "Why does it not reconnect?")),
            .assistant(AssistantTurn(id: "t1", answer: "It reconnects too late.")),
            .user(UserEntry(id: "u2", text: "Fix it")),
            .assistant(AssistantTurn(id: "t2", answer: "Fixed. The socket now  reconnects with backoff when the Mac wakes.")),
        ]
        #expect(focus.target(in: items)?.id == "t2")
        // Without the phrase, the first message with every word.
        #expect(SearchFocus(words: ["reconnects"], phrase: "").target(in: items)?.id == "t1")
        #expect(SearchFocus(words: ["porto"], phrase: "").target(in: items) == nil)
    }

    @Test func aSnippetMarkingEveryWordStillGivesAPhrase() {
        let result = SessionSearchResult(sessionID: "s", snippet: ">>>Step<<< >>>38<<<: check the services on >>>node<<< >>>2<<< and fix what's broken.")
        #expect(SearchFocus(result: result).phrase == "Step 38: check")
        let inWord = SessionSearchResult(sessionID: "s", snippet: "…we re>>>connect<<<ed twice")
        #expect(SearchFocus(result: inWord).phrase == "we reconnected twice")
    }

    @Test func aMatchIsTheResultsMessageNotOneWithItsWords() {
        let focus = SearchFocus(words: ["step", "38", "node", "2"], phrase: "Step 38: check the services on node 2")
        let latest: [TranscriptItem] = [
            .user(UserEntry(id: "u48", text: "Step 48: check the services on node 5 and fix what's broken.")),
            .assistant(AssistantTurn(id: "t48", answer: "Node 5 is healthy again; step 2 of 38 checks passed.")),
        ]
        // The latest rows have every word, but not the result's phrase: load earlier pages first.
        #expect(focus.match(in: latest) == nil)
        #expect(focus.target(in: latest)?.id == "t48")
        let earlier: [TranscriptItem] = [.user(UserEntry(id: "u38", text: "Step 38: check the services on node 2 and fix what's broken."))]
        #expect(focus.match(in: earlier + latest)?.id == "u38")
        // Without a phrase, every word is the match.
        #expect(SearchFocus(words: ["step", "38"], phrase: "").match(in: latest)?.id == "t48")
    }
}
