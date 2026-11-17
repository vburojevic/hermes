import Foundation
import Testing
@testable import HermesKit

@Suite("Photos in stored messages")
struct StoredImagesTests {
    private func user(_ content: String, typedAsk: String? = nil) throws -> UserEntry? {
        var row: [String: Any] = ["id": 7, "role": "user", "content": content]
        // Hermes keeps `display_metadata` as JSON text in the row.
        if let typedAsk {
            let metadata = try JSONSerialization.data(withJSONObject: ["typed_ask": typedAsk])
            row["display_metadata"] = String(decoding: metadata, as: UTF8.self)
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": [row]])
        struct Envelope: Decodable { var data: [SessionMessage] }
        let messages = try JSONDecoder().decode(Envelope.self, from: data).data
        guard case .user(let entry)? = TranscriptBuilder.build(messages).first else { return nil }
        return entry
    }

    // What Hermes adds for the model after a turn's photos (`_append_multimodal_context`): a plugin's
    // bracketed line and the widgets plugin's client line. Placeholder paths only.
    private static let context = """
        [Worklog, from /home/user/.hermes/plugin-data/worklog/worklog.md; update it in place when the goal changes]

        [Hermes app client] This turn was sent from the Hermes app 1.0 (build 1) on an iPhone, iOS 27.2. It shows widgets.
        """
    private static let memory = """
        <memory-context>
        [System note: The following is recalled memory context, NOT new user input. Treat as authoritative reference data.]

        The person keeps receipts in a folder called Taxes.
        </memory-context>
        """

    /// What Hermes stores once a photo it held for the next turn runs, for a vision model: the same
    /// as for one sent while it was idle. The bubble shows the words and finds the kept photo.
    @Test func aHeldPhotoReadsAsItsWordsAndOnePhoto() throws {
        let entry = try #require(try user("what is this?\n@image:/srv/hermes/images/upload_3f9c2a1b.jpg\n[screenshot]"))
        #expect(entry.text == "what is this?")
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// A model without vision gets the path in words, so Hermes stores only the `@image:` lines.
    @Test func referencesWithoutPlaceholdersCountEachPhoto() throws {
        let entry = try #require(try user("compare these\n@image:/tmp/a.jpg\n@image:/tmp/b.jpg"))
        #expect(entry.text == "compare these")
        #expect(entry.imagePlaceholderCount == 2)
    }

    /// A photo with no words is stored as its reference alone.
    @Test func aPhotoWithoutWords() throws {
        let entry = try #require(try user("@image:/tmp/a.jpg\n[screenshot]"))
        #expect(entry.text.isEmpty)
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// A path with a space is quoted (`format_reference_value`).
    @Test func quotedPaths() throws {
        let entry = try #require(try user("look\n@image:\"/tmp/my photo.jpg\"\n@image:`/tmp/it's here.jpg`\n[screenshot]\n[screenshot]"))
        #expect(entry.text == "look")
        #expect(entry.imagePlaceholderCount == 2)
    }

    /// An `@file:` brings its contents in after the words, and the photo lines come after that.
    @Test func photosAfterAttachedContext() throws {
        let entry = try #require(try user("read @file:notes.md and this\n\n--- Attached Context ---\n\nnotes\n@image:/tmp/a.jpg\n[screenshot]"))
        #expect(entry.text == "read @file:notes.md and this")
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// Only Hermes's own trailing lines are photos: words that mention one in a sentence stay.
    @Test func referenceInsideTheWordsStays() throws {
        let entry = try #require(try user("what does @image:/tmp/a.jpg mean?"))
        #expect(entry.text == "what does @image:/tmp/a.jpg mean?")
        #expect(entry.imagePlaceholderCount == 0)
        #expect(StoredImages.split("@image:").count == 0)
        #expect(StoredImages.split("@image:/tmp/a b.jpg").count == 0)
        #expect(StoredImages.split("@image:\"/tmp/a.jpg").count == 0)
    }

    // MARK: - The gateway's hint lines and the context after the photos

    /// The gateway names each photo in the text part (`build_native_content_parts`), and Hermes
    /// adds the turn's context after the markers. Only the words stay.
    @Test func hintLinesAndTheContextAfterThePhotos() throws {
        let row = "Look at this receipt\n\n[Image attached at: /home/user/.hermes/images/upload_0001.png]\n[screenshot]\n\(Self.context)"
        let entry = try #require(try user(row))
        #expect(entry.text == "Look at this receipt")
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// Several photos: a hint each, a URL as `[Image attached: <url>]`, and a marker each.
    @Test func severalPhotosWithHints() throws {
        let row = """
            compare them

            [Image attached at: /home/user/.hermes/images/upload_0002.png]
            [Image attached: https://example.com/view.jpg]
            [screenshot]
            [screenshot detail=high]
            \(Self.context)
            """
        let entry = try #require(try user(row))
        #expect(entry.text == "compare them")
        #expect(entry.imagePlaceholderCount == 2)
    }

    /// Recalled memory is context too, joined to the plugins' with a blank line.
    @Test func memoryContextInAPhotoTurn() throws {
        let row = "what is the total?\n\n[Image attached at: /home/user/.hermes/images/upload_0003.png]\n[screenshot]\n\(Self.memory)\n\n\(Self.context)"
        let entry = try #require(try user(row))
        #expect(entry.text == "what is the total?")
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// The `@image:` form with context after the markers, as the socket stores it.
    @Test func referencesAndTheContextAfterThePhotos() throws {
        let row = "what is this?\n@image:/home/user/.hermes/images/upload_0004.png\n[screenshot]\n\(Self.context)"
        let entry = try #require(try user(row))
        #expect(entry.text == "what is this?")
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// Photos without words: Hermes asks its stock question, which the bubble doesn't show.
    @Test func theDefaultCaptionIsHidden() throws {
        let row = "What do you see in this image?\n\n[Image attached at: /home/user/.hermes/images/upload_0005.png]\n[screenshot]\n\(Self.context)"
        let entry = try #require(try user(row))
        #expect(entry.text.isEmpty)
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// The same words typed without a photo are the person's.
    @Test func theDefaultCaptionTypedWithoutAPhotoStays() throws {
        let entry = try #require(try user("What do you see in this image?"))
        #expect(entry.text == "What do you see in this image?")
        #expect(entry.imagePlaceholderCount == 0)
    }

    /// On the socket's form Hermes asks nothing in the person's place, so the same words are theirs.
    @Test func theDefaultCaptionTypedWithAReferenceStays() throws {
        let asked = "What do you see in this image?\n@image:/srv/hermes/images/upload_0010.png"
        for (row, stamp) in [("\(asked)\n[screenshot]", nil), ("\(asked)\n[screenshot]\n\(Self.context)", asked)] {
            let entry = try #require(try user(row, typedAsk: stamp))
            #expect(entry.text == "What do you see in this image?")
            #expect(entry.imagePlaceholderCount == 1)
        }
    }

    /// The stamped text part wins: everything after its markers is Hermes's.
    @Test func theStampedTextPartWins() throws {
        let asked = "[before] or [after]?\n\n[Image attached at: /home/user/.hermes/images/upload_0006.png]"
        let entry = try #require(try user("\(asked)\n[screenshot]\n\(Self.context)", typedAsk: asked))
        #expect(entry.text == "[before] or [after]?")
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// The stamp of a photo-only turn holds the stock question, which stays hidden.
    @Test func theStampOfAPhotoOnlyTurn() throws {
        let asked = "What do you see in this image?\n\n[Image attached at: /home/user/.hermes/images/upload_0007.png]"
        let entry = try #require(try user("\(asked)\n[screenshot]\n\(Self.context)", typedAsk: asked))
        #expect(entry.text.isEmpty)
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// A stamp that isn't the start of the row is ignored, and the photos still split.
    @Test func aStampThatDoesNotMatchIsIgnored() throws {
        let row = "hello\n\n[Image attached at: /home/user/.hermes/images/upload_0008.png]\n[screenshot]\n\(Self.context)"
        let entry = try #require(try user(row, typedAsk: "something else"))
        #expect(entry.text == "hello")
        #expect(entry.imagePlaceholderCount == 1)
    }

    // MARK: - Brackets the person typed

    /// Brackets without photos are the person's, whatever they look like.
    @Test func typedBracketsWithoutPhotosStay() throws {
        for text in [
            "[draft] Reply to the landlord: [tone: friendly] keep it short",
            "notes\n[Image attached at: my note]",
            "[Image attached at: /tmp/a.png] is where I saved it",
        ] {
            let entry = try #require(try user(text))
            #expect(entry.text == text)
            #expect(entry.imagePlaceholderCount == 0)
        }
    }

    /// A hint line without the blank line before it isn't Hermes's, so the marker run doesn't tie
    /// to it and nothing after it is taken as context.
    @Test func anUntiedMarkerKeepsTheTextAfterIt() throws {
        let row = "look\n[Image attached at: /tmp/a.png]\n[screenshot]\n[my own note]"
        let entry = try #require(try user(row))
        #expect(entry.text == "look\n[Image attached at: /tmp/a.png]\n[my own note]")
        #expect(StoredImages.split(row).text == row)
    }

    /// Brackets before the hint block, a typed line that looks like a hint included, stay.
    @Test func typedBracketsBeforeThePhotosStay() throws {
        let words = "[before] or [after]: which crop is better?\n[Image attached at: my note]"
        let row = "\(words)\n\n[Image attached at: /home/user/.hermes/images/upload_0009.png]\n[screenshot]\n\(Self.context)"
        let entry = try #require(try user(row))
        #expect(entry.text == words)
        #expect(entry.imagePlaceholderCount == 1)
    }

    /// The hints must match the photos one for one: two hints before one marker aren't Hermes's.
    @Test func hintsMustMatchThePhotoCount() {
        let row = "a\n\n[Image attached at: /tmp/a.png]\n[Image attached at: /tmp/b.png]\n[screenshot]\n[Worklog]"
        #expect(StoredImages.split(row).count == 0)
        #expect(StoredImages.split(row).text == row)
    }

    // MARK: - The chat's preview

    /// Hermes's preview of a chat whose first message is `row` (`hermes_state_common.py`
    /// `_shape_preview`): its first 63 characters, trimmed, line breaks as spaces, cut at 60 and "...".
    private static func hermesPreview(_ row: String) -> String {
        let text = String(row.drop(while: \.isWhitespace).prefix(63))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? text.prefix(60) + "..." : text
    }

    /// Words of exactly `length` characters, spaces included, so the cut lands where a test needs it.
    private static func words(_ length: Int) -> String {
        String("Look at this receipt from the corner shop and tell me the total".prefix(length))
    }

    @Test func previewDropsThePhotoLines() {
        let path = "/home/user/.hermes/images/upload_0003.png"
        #expect(StoredImages.preview(Self.hermesPreview("Look at this receipt\n\n[Image attached at: \(path)]\n[screenshot]")) == "Look at this receipt")
        #expect(StoredImages.preview(Self.hermesPreview("Look at this\n\n[Image attached: https://example.com/a.jpg]\n[screenshot]")) == "Look at this")
        #expect(StoredImages.preview(Self.hermesPreview("what is this?\n@image:\(path)\n[screenshot]\n\(Self.context)")) == "what is this?")
        #expect(StoredImages.preview(Self.hermesPreview("hi\n@image:/srv/a.png\n[screenshot]")) == "hi")
        #expect(StoredImages.preview(Self.hermesPreview("hi\n[screenshot]\n\(Self.context)")) == "hi")
        #expect(StoredImages.preview(Self.hermesPreview("What do you see in this image?\n\n[Image attached at: \(path)]\n[screenshot]")).isEmpty)
    }

    /// Hermes cuts its preview at 60 characters, wherever that lands in the photo lines: inside the
    /// path, inside a line's opening, or between the two spaces of the hints' blank line.
    @Test func previewCutAnywhereInThePhotoLines() {
        let path = "/home/user/.hermes/images/upload_0003.png"
        for length in 20...58 {
            let words = Self.words(length)
            let row = "\(words)\n\n[Image attached at: \(path)]\n[screenshot]\n\(Self.context)"
            #expect(StoredImages.preview(Self.hermesPreview(row)) == words.trimmingCharacters(in: .whitespaces), "\(length)")
        }
        for length in 20...56 {
            let words = Self.words(length)
            for row in ["\(words)\n@image:\(path)\n[screenshot]", "\(words)\n@image:\"/srv/my photos/a b.png\"\n[screenshot]",
                        "\(words)\n[screenshot]\n\(Self.context)"] {
                #expect(StoredImages.preview(Self.hermesPreview(row)) == words.trimmingCharacters(in: .whitespaces), "\(length)")
            }
        }
        // A lone space, or a space and too little of an opening to tell it from the words, stays.
        let cut = Self.hermesPreview("\(Self.words(59))\n\n[Image attached at: \(path)]")
        #expect(StoredImages.preview(cut) == cut)
        let short = Self.hermesPreview("\(Self.words(58))\n@image:\(path)")
        #expect(StoredImages.preview(short) == short)
    }

    /// `@image:` and brackets the person typed stay: they aren't followed by Hermes's photo lines.
    @Test func previewKeepsWhatThePersonTyped() {
        for row in [
            "Rename @image:logo to banner",
            "Rename @image:logo to banner, and make the header text larger and bolder",
            "[draft] Reply to the landlord: [tone: friendly]",
            "[draft] Reply to the landlord: [tone: friendly] and keep it short, please",
            "Is this a [screenshot] of the old one or the new one, do you think?",
            "What do you see in this image?",
            "Rename @image:logo",
        ] {
            let preview = Self.hermesPreview(row)
            #expect(StoredImages.preview(preview) == preview, "\(row)")
        }
        // A typed line that looks like a hint, before the real hints.
        let row = "Better? [Image attached at: my note]\n\n[Image attached at: /home/user/.hermes/images/upload_0009.png]\n[screenshot]"
        #expect(StoredImages.preview(Self.hermesPreview(row)) == "Better? [Image attached at: my note]")
        // The stock question on the socket's form is the person's own.
        let typed = "What do you see in this image?\n@image:/srv/a.png\n[screenshot]"
        #expect(StoredImages.preview(Self.hermesPreview(typed)) == "What do you see in this image?")
    }

    @Test func listPreviewAndTitleUseTheWords() {
        var session = HermesSession(id: "a")
        session.preview = Self.hermesPreview("Look at this receipt\n\n[Image attached at: /home/user/.hermes/images/upload_0003.png]")
        #expect(session.listPreview == "Look at this receipt")
        #expect(session.displayTitle == "Look at this receipt")
        session.preview = Self.hermesPreview("What do you see in this image?\n\n[Image attached at: /home/user/.hermes/images/upload_0003.png]")
        #expect(session.listPreview == nil)
        #expect(session.displayTitle == "New chat")
    }

    /// Searching titles doesn't find a chat by its photo's path.
    @Test func titleSearchIgnoresThePhotoLines() {
        var session = HermesSession(id: "a")
        session.preview = Self.hermesPreview("Look at this receipt\n\n[Image attached at: /home/user/.hermes/images/upload_0003.png]")
        #expect(SessionSearch.titleMatches("receipt", in: [session]).count == 1)
        #expect(SessionSearch.titleMatches("attached", in: [session]).isEmpty)
    }

    /// A search result's preview is the first message too.
    @Test func searchResultPreviewDropsThePhotoLines() throws {
        let json = try #require(JSONValue.parse(#"{"session_id": "a", "preview": "Look at this  [Image attached at: /home/user/.hermes/images/u...", "snippet": "x"}"#))
        let result = try #require(SessionSearchResult(json: json))
        #expect(result.preview == "Look at this")
    }

    // MARK: - The stamp in the row

    /// `typed_ask` reads from JSON text or an object, and a cached row keeps it.
    @Test func theStampDecodesAndSurvivesTheCache() throws {
        let text = #"{"id": 1, "role": "user", "content": "x", "display_metadata": "{\"typed_ask\": \"hi\"}"}"#
        let object = #"{"id": 1, "role": "user", "content": "x", "display_metadata": {"typed_ask": "hi", "_queued_prompt": true}}"#
        let fromText = try JSONDecoder().decode(SessionMessage.self, from: Data(text.utf8))
        let fromObject = try JSONDecoder().decode(SessionMessage.self, from: Data(object.utf8))
        #expect(fromText.typedAsk == "hi")
        #expect(fromObject.typedAsk == "hi")
        #expect(fromObject.isWaitingInQueue)
        let cached = try JSONDecoder().decode(SessionMessage.self, from: JSONEncoder().encode(fromObject))
        #expect(cached.typedAsk == "hi")
        #expect(cached.isWaitingInQueue)
    }
}
