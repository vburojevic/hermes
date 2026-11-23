import Foundation
import Testing
@testable import HermesKit

/// A page a reply shows live with `::preview{…}` (`docs/chat.md` §3c).
@Suite("Page previews")
struct PagePreviewTests {
    @Test func parsesFileAndHeight() {
        #expect(PreviewDirective.parse(#"::preview{file="exports/board.html" height="360"}"#)
            == PreviewDirective(file: "exports/board.html", height: 360))
        #expect(PreviewDirective.parse(#"  ::preview{file='~/site/index.htm'}  "#) == PreviewDirective(file: "~/site/index.htm"))
        #expect(PreviewDirective.parse(#"::preview{height="200", file="a b/c.html"}"#)?.file == "a b/c.html")
    }

    @Test func heightIsKeptInItsBand() {
        #expect(PreviewDirective.parse(#"::preview{file="a.html" height="40"}"#)?.height == 120)
        #expect(PreviewDirective.parse(#"::preview{file="a.html" height="5000"}"#)?.height == 1200)
        // Not a whole number: no height asked for, as the desktop reads it.
        #expect(PreviewDirective.parse(#"::preview{file="a.html" height="12.5"}"#)?.height == nil)
        #expect(PreviewDirective.parse(#"::preview{file="a.html" height="tall"}"#)?.height == nil)
        #expect(PreviewDirective(file: "a.html").startHeight == 280)
        #expect(PreviewDirective.measured(90) == 120)
        #expect(PreviewDirective.measured(640.4) == 640)
        #expect(PreviewDirective.measured(.infinity) == nil)
        #expect(PreviewDirective.measured(0) == nil)
    }

    @Test func malformedIsNotADirective() {
        #expect(PreviewDirective.parse(#"::preview{height="300"}"#) == nil)
        #expect(PreviewDirective.parse(#"::preview{file=""}"#) == nil)
        #expect(PreviewDirective.parse(#"See ::preview{file="a.html"}"#) == nil)
        #expect(PreviewDirective.parse(#"::preview{file="a.html"} too"#) == nil)
        #expect(PreviewDirective.parse(#"::preview{file="a.html}"#) == nil)
        #expect(PreviewDirective.parse(#"::preview{file="{a}.html"}"#) == nil)
        #expect(PreviewDirective.parse(#"::preview{file="a.html'}"#) == nil)
        #expect(PreviewDirective.parse("::preview{file=\"" + String(repeating: "a", count: 3000) + ".html\"}") == nil)
    }

    @Test func onlyPagesOpenLive() {
        #expect(PreviewDirective(file: "/srv/out/Report.HTML").isPage)
        #expect(PreviewDirective(file: "x.xhtml").isPage)
        #expect(!PreviewDirective(file: "notes.md").isPage)
        #expect(!PreviewDirective(file: "html").isPage)
        #expect(PreviewDirective(file: "/srv/out/board.html").fileName == "board.html")
        #expect(PreviewDirective(file: "board.html").fileName == "board.html")
    }

    @Test func resolvesAgainstTheChatsFolder() {
        #expect(PreviewDirective(file: "/srv/a.html").path(in: nil) == "/srv/a.html")
        #expect(PreviewDirective(file: "~/a.html").path(in: "/work") == "~/a.html")
        #expect(PreviewDirective(file: "./out/a.html").path(in: "/work/") == "/work/out/a.html")
        #expect(PreviewDirective(file: "out/a.html").path(in: nil) == nil)
        #expect(PreviewDirective(file: "../secret/a.html").path(in: "/work") == nil)
        #expect(PreviewDirective(file: "/srv/../etc/a.html").path(in: nil) == nil)
    }

    @Test func lineRoundTrips() {
        let directive = PreviewDirective(file: #"odd "name".html"#, height: 400)
        #expect(PreviewDirective.parse(directive.line) == directive)
    }

    @Test func splitsOutsideCodeOnly() {
        let text = """
        Here is the board.

        ::preview{file="exports/board.html"}

        ```
        ::preview{file="not/this.html"}
        ```
        Done.
        """
        let segments = ReplySplitter.split(text)
        #expect(segments.count == 3)
        #expect(segments[1] == .preview(PreviewDirective(file: "exports/board.html")))
        if case .markdown(let tail) = segments[2] { #expect(tail.contains("not/this.html")) } else { Issue.record("expected code") }
        #expect(ReplySplitter.readableText(text).contains("exports/board.html"))
    }

    @Test func streamingHoldsAHalfDirective() {
        #expect(ReplySplitter.split("Look:\n::prev", streaming: true) == [.markdown("Look:")])
        #expect(ReplySplitter.split("Look:\n::preview{file=\"a.ht", streaming: true) == [.markdown("Look:")])
        #expect(ReplySplitter.split("Look:\n::preview{file=\"a.html\"}\n", streaming: true)
            == [.markdown("Look:"), .preview(PreviewDirective(file: "a.html"))])
    }

    @Test func spokenAsItsFileName() {
        let words = SpokenWidgets.words(of: "Open it:\n::preview{file=\"/srv/out/board.html\"}", inlineWidgets: false, stored: { _ in nil })
        #expect(words.text == "Open it:\n\nboard.html")
    }

    @Test func intentsAreChecked() {
        #expect(PageIntent.evaluate("  price eth \n", now: 5000, lastAccepted: nil) == .accept("price eth"))
        #expect(PageIntent.evaluate("   ", now: 0, lastAccepted: nil) == .reject(.invalid))
        #expect(PageIntent.evaluate(42, now: 0, lastAccepted: nil) == .reject(.invalid))
        #expect(PageIntent.evaluate(nil, now: 0, lastAccepted: nil) == .reject(.invalid))
        #expect(PageIntent.evaluate(String(repeating: "a", count: 500), now: 0, lastAccepted: nil) == .accept(String(repeating: "a", count: 500)))
        #expect(PageIntent.evaluate(String(repeating: "a", count: 501), now: 0, lastAccepted: nil) == .reject(.tooLong))
        // Counted as the page counts it: an emoji is two.
        #expect(PageIntent.evaluate(String(repeating: "😀", count: 251), now: 0, lastAccepted: nil) == .reject(.tooLong))
        #expect(PageIntent.evaluate("again", now: 1300, lastAccepted: 1000) == .reject(.throttled(retryAfterMilliseconds: 700)))
        #expect(PageIntent.evaluate("again", now: 2000, lastAccepted: 1000) == .accept("again"))
    }

    @Test func acksMatchTheDesktop() {
        #expect(PageIntent.ack(nil) == ["ok": .bool(true)])
        #expect(PageIntent.ack(.tooLong) == ["ok": .bool(false), "error": .string("too_long"), "maxLength": .number(500)])
        #expect(PageIntent.ack(.throttled(retryAfterMilliseconds: 250)) == ["ok": .bool(false), "error": .string("throttled"), "retryAfterMs": .number(250)])
        #expect(PageIntent.ack(.declined)["error"] == .string("declined"))
        #expect(PageIntent.ack(.declined)["reason"] != nil)
        #expect(PageIntent.ack(.undelivered) == ["ok": .bool(false), "error": .string("undelivered")])
    }

    @Test func frameGoesAroundThePage() {
        #expect(PageFrame.assemble("<!DOCTYPE html><html lang=en><HEAD><title>T</title></head><body><p>Hi</p></BODY></html>", prelude: "<P>", scripts: "<S>")
            == "<!DOCTYPE html><html lang=en><HEAD><P><title>T</title></head><body><p>Hi</p><S></BODY></html>")
        #expect(PageFrame.assemble("<!doctype html><header>x</header>", prelude: "<P>") == "<!doctype html><P><header>x</header>")
        #expect(PageFrame.assemble("<html><body>x</body></html>", prelude: "<P>") == "<html><P><body>x</body></html>")
        #expect(PageFrame.assemble("<p>Hi</p>", prelude: "<P>", scripts: "<S>") == "<P><p>Hi</p><S>")
        let prelude = PageFrame.prelude(dark: true, variables: [("--foreground", "#fff")], font: "-apple-system")
        #expect(prelude.contains("color-scheme:dark;--foreground:#fff"))
        #expect(prelude.hasPrefix("<style>"))
    }

    @Test func titleIsRead() {
        #expect(PageFrame.title(of: "<html><head><TITLE lang=en>\n Q3   board &amp; plans </title></head>") == "Q3 board & plans")
        #expect(PageFrame.title(of: "<html><body>No title</body></html>") == nil)
        #expect(PageFrame.title(of: "<title>   </title>") == nil)
        #expect(PageFrame.title(of: "<title>" + String(repeating: "a", count: 300) + "</title>")?.count == 120)
    }
}
