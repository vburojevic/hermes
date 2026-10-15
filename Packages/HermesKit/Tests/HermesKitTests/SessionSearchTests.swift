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
        #expect(result.date == Date(timeIntervalSince1970: 1760531400.5) && result.lastActive == nil)
        #expect(result.matchedWords == ["reconnect"] && !result.isTaskRun)
        let task = try #require(JSONValue.parse(#"{"id": "cron_1", "source": "cron", "snippet": "x"}"#).flatMap(SessionSearchResult.init(json:)))
        #expect(task.isTaskRun && task.sessionID == "cron_1")
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
}
