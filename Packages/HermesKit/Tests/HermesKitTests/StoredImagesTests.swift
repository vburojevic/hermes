import Foundation
import Testing
@testable import HermesKit

@Suite("Photos in stored messages")
struct StoredImagesTests {
    private func user(_ content: String) throws -> UserEntry? {
        let row: [String: Any] = ["id": 7, "role": "user", "content": content]
        let data = try JSONSerialization.data(withJSONObject: ["data": [row]])
        struct Envelope: Decodable { var data: [SessionMessage] }
        let messages = try JSONDecoder().decode(Envelope.self, from: data).data
        guard case .user(let entry)? = TranscriptBuilder.build(messages).first else { return nil }
        return entry
    }

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
}
