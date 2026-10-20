import Foundation
@testable import HermesKit
@testable import HermesMarkdown
import Testing

/// A reply that repeats a routine's brief: one line of words, then the brief's widget as one long
/// line of JSON in a json fence (the plugin turns a widget fence it didn't write into json). The
/// shape is a real one from 2026-10-20, with neutral words; on the iPhone it drew an empty frame.
@Suite("Echoed widgets")
struct EchoedWidgetTests {
    private static func story(_ n: Int) -> String {
        let words = String(repeating: "Release notes, a changelog and a migration guide for version \(n). ", count: 6)
        return #"{"type":"story","v":1,"id":"w_story\#(n)aa","title":"Story \#(n)","story":{"headline":"Story \#(n)","body":"\#(words)","sources":[{"name":"Example","url":"https://example.com/\#(n)"}]},"fallback_text":"Story \#(n)"}"#
    }

    private static let payload = #"{"type":"stack","v":1,"id":"w_Brief20261020","rev":1,"title":"Morning brief","children":["#
        + (1...9).map(story).joined(separator: ",") + #"],"fallback_text":"Morning brief"}"#
    static let reply = "Release day: three tools ship updates and two need a look.\n\n```json\n\(payload)\n```"

    @Test func theReplyParsesToTheWholeJSON() throws {
        #expect(Self.payload.count > 5_000 && !Self.payload.contains("\n"))
        let blocks = MarkdownDocument(parsing: Self.reply).blocks
        #expect(blocks.count == 2)
        guard case .codeBlock(let language, let code)? = blocks.last else { Issue.record("no code block"); return }
        #expect(language == "json")
        #expect(code.trimmingCharacters(in: .newlines) == Self.payload)
        #expect(MarkdownDocument.boundedNesting(Self.reply) == Self.reply)
    }

    @Test func itNamesTheWidgetItCopies() throws {
        let echo = try #require(ReplySplitter.echoedWidget(language: "json", code: Self.payload))
        #expect(echo.id == "w_Brief20261020" && echo.rev == 1)
        #expect(ReplySplitter.echoedWidget(language: "swift", code: Self.payload) == nil)
        #expect(ReplySplitter.echoedWidget(language: "json", code: #"{"name": "not a widget"}"#) == nil)
        #expect(ReplySplitter.echoedWidget(language: "json", code: #"{"type":"metric","id":"../etc"}"#) == nil)
    }

    /// A line this long can't scroll sideways as one run (it drew nothing), so it wraps, and the
    /// block shows its start with Copy for the rest.
    @Test func aLongLineWrapsAndALongBlockShowsItsStart() {
        #expect(CodeBlockLayout.wraps(Self.payload))
        #expect(!CodeBlockLayout.wraps("let x = 1\nprint(x)"))
        let shown = CodeBlockLayout.shown(Self.payload)
        #expect(shown.text.count == CodeBlockLayout.shownCharacters)
        #expect(shown.hidden == Self.payload.count - CodeBlockLayout.shownCharacters)
        let lines = (1...400).map { "line \($0) of a long log" }.joined(separator: "\n")
        let cut = CodeBlockLayout.shown(lines)
        #expect(cut.text.hasSuffix("long log") && cut.hidden > 0, "cut at a line end")
        #expect(CodeBlockLayout.shown("short").hidden == 0)
    }
}
