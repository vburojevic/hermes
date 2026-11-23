import Foundation
import Testing
@testable import HermesKit

/// Files Hermes sends with `MEDIA:` lines (`docs/chat.md` §3a): which lines are files, what each
/// is and where it opens, where the chat draws them, and that every plain-text use of a reply
/// still reads a note, never a raw path.
@Suite("Files a reply sends")
struct ReplyAttachmentTests {
    private static let reply = """
    Here's what I made.

    MEDIA:/Users/me/out/chart.png
    MEDIA:/Users/me/out/walkthrough.mp4

    The report and the notes:
    MEDIA:/Users/me/out/report.pdf
    MEDIA:`/Users/me/out/notes.md`
    "MEDIA:/Users/me/out/page.html"
    MEDIA:/Users/me/out/bundle.zip
    """

    // MARK: Which lines are files

    @Test func eachKindIsReadFromItsExtension() {
        let files = ReplyAttachment.parse(Self.reply)
        #expect(files.map(\.fileName) == ["chart.png", "walkthrough.mp4", "report.pdf", "notes.md", "page.html", "bundle.zip"])
        #expect(files.map(\.kind) == [.picture, .video, .document, .document, .document, .file])
        #expect(files.map(\.opens) == [.fileTab, .fileTab, .preview, .fileTab, .preview, .save])
        #expect(files.map(\.typeName) == ["PNG", "MPEG-4 video", "PDF", "Markdown", "HTML page", "ZIP archive"])
        #expect(files[3].path == "/Users/me/out/notes.md", "backticks are stripped, as AgentAudio strips them")
    }

    @Test func onlyAbsoluteFilesWithAnExtensionOutsideCodeAreFiles() {
        let text = """
        MEDIA:out/chart.png
        MEDIA:/Users/me/out/README
        MEDIA:/Users/me/out/
        MEDIA:/Users/me/.env
        MEDIA://server/share/x.png
        MEDIA:~/Desktop/shot.jpg
        ```
        MEDIA:/Users/me/example.png
        ```
        See MEDIA:/Users/me/inline.png here
        MEDIA:/tmp/tts/summary.mp3
        """
        #expect(ReplyAttachment.parse(text).map(\.path) == ["~/Desktop/shot.jpg"])
        #expect(ReplyAttachment(path: "/tmp/voice.ogg") == nil, "audio is a listen strip")
    }

    @Test func filesOpenWhereTheInspectorCanShowThem() {
        #expect(GatewayFileOpening.destination(for: "/a/notes.md") == .fileTab)
        #expect(GatewayFileOpening.destination(for: "/a/data.csv") == .fileTab)
        #expect(GatewayFileOpening.destination(for: "/a/main.swift") == .fileTab)
        #expect(GatewayFileOpening.destination(for: "/a/shot.png") == .fileTab)
        #expect(GatewayFileOpening.destination(for: "/a/report.PDF") == .preview)
        #expect(GatewayFileOpening.destination(for: "/a/index.htm") == .preview)
        #expect(GatewayFileOpening.destination(for: "/a/bundle.zip") == .save)
        #expect(GatewayFileOpening.destination(for: "/a/deck.pptx") == .quickLook)
        #expect(GatewayFileOpening.destination(for: "/a/Plan.DOCX") == .quickLook)
        #expect(GatewayFileOpening.destination(for: "/a/budget.ods") == .save, "Quick Look doesn't draw it")
        #expect(GatewayFileOpening.destination(for: "/a/deck.odp") == .save)
        #expect(GatewayFileOpening.destination(for: "/a/brief.rtf") == .quickLook)
        #expect(GatewayFileOpening.destination(for: "/a/q3.numbers") == .quickLook)
        #expect(ReplyAttachment(path: "/a/deck.pptx")?.kind == .document, "a card that opens")
        #expect(ReplyAttachment(path: "/a/brief.odt")?.typeName == "OpenDocument text")
        #expect(GatewayFileOpening.destination(for: "/a/Makefile") == .save)
        #expect(GatewayFileOpening.opensInPreview("/a/report.pdf"))
        #expect(!GatewayFileOpening.opensInPreview("/a/notes.md"))
    }

    @Test func aQuickLookCopyIsKeptApartByPathAndProfile() {
        let one = QuickLookCopy.folderName(path: "/srv/out/plan.docx", profile: "writer")
        #expect(one.count == 32 && one.allSatisfy(\.isHexDigit))
        #expect(one == QuickLookCopy.folderName(path: "/srv/out/plan.docx", profile: "writer"))
        #expect(one != QuickLookCopy.folderName(path: "/srv/out/plan.docx", profile: "ops"))
        #expect(one != QuickLookCopy.folderName(path: "/srv/old/plan.docx", profile: "writer"))
        #expect(QuickLookCopy.folderName(path: "/a", profile: nil) == QuickLookCopy.folderName(path: "/a", profile: ""))
        #expect(QuickLookCopy.fileName(of: "/srv/out/Q3 plan.docx") == "Q3 plan.docx")
        #expect(QuickLookCopy.fileName(of: "/srv/out/..hidden.xlsx") == "hidden.xlsx")
        #expect(QuickLookCopy.fileName(of: "/srv/a:b.rtf") == "a_b.rtf")
        #expect(QuickLookCopy.fileName(of: "/") == "file")
        let long = QuickLookCopy.fileName(of: "/a/" + String(repeating: "x", count: 300) + ".pptx")
        #expect(long.count == 120 && long.hasSuffix(".pptx"))
    }

    @Test func theViewerReadsTheSameFile() throws {
        for path in ["/Users/me/out/chart.png", "/Users/me/My Shots/50% done #2.png", "~/clip.mov"] {
            let file = try #require(ReplyAttachment(path: path))
            #expect(WidgetFile.path(file.media.src) == path)
            #expect(WidgetFile.resolve(file.media.src, in: nil) == path, "an absolute path needs no folder")
        }
        #expect(ReplyAttachment(path: "/a/clip.mp4")?.media.kind == .video)
        #expect(ReplyAttachment(path: "/a/chart.png")?.media.alt == "chart.png")
    }

    // MARK: Where the chat draws them

    @Test func filesDrawWhereTheirNotesAreAndNeighboursGoTogether() {
        let text = TranscriptBuilder.cleanAssistantText(Self.reply)
        let files = ReplyAttachment.parse(Self.reply)
        let segments = ReplySplitter.split(text, attachments: files)
        guard segments.count == 4,
              case .markdown(let intro) = segments[0], case .attachments(let media) = segments[1],
              case .markdown(let middle) = segments[2], case .attachments(let documents) = segments[3]
        else { Issue.record("segments: \(segments)"); return }
        #expect(intro == "Here's what I made.")
        #expect(media.map(\.fileName) == ["chart.png", "walkthrough.mp4"])
        #expect(middle == "The report and the notes:")
        #expect(documents.map(\.fileName) == ["report.pdf", "notes.md", "page.html", "bundle.zip"])
        #expect(ReplyAttachment.viewerFiles(in: segments).map(\.fileName) == ["chart.png", "walkthrough.mp4"])
    }

    @Test func aNoteDrawsOnlyWithItsFileAndNeverInCode() {
        let files = ReplyAttachment.parse("MEDIA:/a/chart.png")
        let text = """
        *Attachment on server: chart.png*
        ```
        *Attachment on server: chart.png*
        ```
        *Attachment on server: chart.png*
        *Attachment on server: other.png*
        """
        let segments = ReplySplitter.split(text, attachments: files)
        let drawn = segments.flatMap { segment -> [ReplyAttachment] in
            if case .attachments(let files) = segment { files } else { [] }
        }
        #expect(drawn.map(\.fileName) == ["chart.png"], "each file draws once")
        #expect(segments.count == 2)
        // Without the turn's files nothing is split, as before.
        #expect(ReplySplitter.split(text) == [.markdown(text)])
    }

    // MARK: Plain text

    @Test func everyPlainTextUseReadsNotes() {
        let messages = [
            SessionMessage(id: 1, role: "user", content: .text("Send me the chart")),
            SessionMessage(id: 2, role: "assistant", content: .text(Self.reply)),
        ]
        let items = TranscriptBuilder.build(messages)
        guard case .assistant(let turn)? = items.last else { Issue.record("no reply"); return }
        #expect(turn.attachments.map(\.fileName) == ["chart.png", "walkthrough.mp4", "report.pdf", "notes.md", "page.html", "bundle.zip"])
        for text in [turn.answer, turn.copyableText, turn.previewText,
                     SpokenWidgets.words(of: turn.answer, inlineWidgets: true, stored: { _ in nil }).text,
                     ReplySplitter.readableText(turn.answer)] {
            #expect(!text.contains("MEDIA:"))
            #expect(!text.contains("/Users/me"))
            #expect(text.contains("*Attachment on server: notes.md*"))
        }
        #expect(turn.answer.contains("*Attachment on server: page.html*"), "a quoted line is a note too")
    }

    @Test func theyAreOnlyAnAssistantsFiles() {
        let messages = [
            SessionMessage(id: 1, role: "user", content: .text("MEDIA:/Users/me/out/chart.png")),
            SessionMessage(id: 2, role: "assistant", content: .text("Looking."), toolCalls: [
                ToolCall(id: "c1", name: "terminal", arguments: "{\"command\":\"ls\"}"),
            ]),
            SessionMessage(id: 3, role: "tool", content: .text("MEDIA:/Users/me/out/tool.png"), toolCallID: "c1", toolName: "terminal"),
            SessionMessage(id: 4, role: "assistant", content: .text("Nothing new.")),
        ]
        let items = TranscriptBuilder.build(messages)
        for item in items {
            if case .assistant(let turn) = item { #expect(turn.attachments.isEmpty) }
        }
    }

    @Test func audioStaysAListenStrip() {
        let messages = [SessionMessage(id: 1, role: "assistant", content: .text("[[audio_as_voice]]\nMEDIA:/tmp/tts/reply.ogg\nMEDIA:/tmp/out/chart.png\n\nHere."))]
        guard case .assistant(let turn)? = TranscriptBuilder.build(messages).last else { Issue.record("no reply"); return }
        #expect(turn.audio == [AgentAudio(path: "/tmp/tts/reply.ogg", isVoice: true)])
        #expect(turn.attachments.map(\.path) == ["/tmp/out/chart.png"])
        #expect(!turn.answer.contains("reply.ogg"))
    }

    // MARK: Streaming

    @Test func aLineStillArrivingNeverShowsRawOrHalfNamed() {
        var live = LiveTurn(id: "t1", sessionID: "s1")
        func send(_ delta: String) { live.apply(SequencedTurnEvent(seq: nil, event: .textDelta(delta))) }
        send("Here's the chart.\n")
        send("MED")
        #expect(live.snapshot.answer == "Here's the chart.")
        send("IA:/Users/me/out/cha")
        #expect(live.snapshot.answer == "Here's the chart.")
        #expect(live.snapshot.attachments.isEmpty)
        send("rt.png\n")
        #expect(live.snapshot.answer == "Here's the chart.\n*Attachment on server: chart.png*")
        #expect(live.snapshot.attachments.map(\.fileName) == ["chart.png"])
        // A line that only starts like one shows as soon as it can't be one.
        send("Mostly blue.")
        #expect(live.snapshot.answer.hasSuffix("Mostly blue."))
        // One the turn ends on, with no newline after it, settles when the turn does.
        send("\nMEDIA:/Users/me/out/data.csv")
        #expect(live.snapshot.attachments.count == 1)
        live.apply(SequencedTurnEvent(seq: nil, event: .completed(output: nil, usage: nil, runtime: nil)))
        #expect(live.turn.attachments.map(\.fileName) == ["chart.png", "data.csv"])
        #expect(live.turn.answer.hasSuffix("*Attachment on server: data.csv*"))
    }

    @Test func onlyMediaLookingLinesAreHeldBack() {
        #expect(ReplyAttachment.mayBeArriving("M"))
        #expect(ReplyAttachment.mayBeArriving("`MEDIA:/a"))
        #expect(ReplyAttachment.mayBeArriving("  MEDIA:"))
        #expect(!ReplyAttachment.mayBeArriving("Mo"))
        #expect(!ReplyAttachment.mayBeArriving("The MEDIA: line"))
        #expect(ReplyAttachment.holdingBackArrival("Hi\nMEDIA:/a") == "Hi\n")
        #expect(ReplyAttachment.holdingBackArrival("Hi\nMEDIA:/a.png\n") == "Hi\nMEDIA:/a.png\n")
    }
}
