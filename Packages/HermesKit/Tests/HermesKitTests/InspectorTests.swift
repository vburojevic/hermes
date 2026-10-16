import Foundation
import Testing
@testable import HermesKit

@Suite("Inspector")
struct InspectorTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Artifacts (`artifact-detect.ts`)

    private let pricingPage = """
    <!doctype html>
    <html><head><title>Pricing card</title><style>body { font-family: system-ui; }</style></head>
    <body><div class="card"><h1>Free</h1><p>$0</p></div><div class="card pro"><h1>Pro</h1><p>$8</p></div></body></html>
    """

    @Test func anHTMLDocumentInAReplyIsAnArtifact() {
        let reply = "Here's version 1:\n\n```html\n\(pricingPage)\n```\n\nTell me what to change."
        let found = ArtifactDetector.artifacts(in: reply)
        #expect(found.count == 1)
        #expect(found.first?.detection.kind == .html)
        #expect(found.first?.detection.title == "Pricing card")
        #expect(found.first?.detection.slug == "html:html:pricing-card")
        #expect(ArtifactDetector.fileName(for: found[0].detection) == "pricing-card.html")
    }

    @Test func smallFencesStayInline() {
        #expect(ArtifactDetector.detect(language: "html", code: "<p>Hi</p>") == nil)
        #expect(ArtifactDetector.detect(language: "swift", code: "let x = 1\nprint(x)") == nil)
        #expect(ArtifactDetector.detect(language: "svg", code: "<svg><circle r='4'/></svg>") == nil)
        #expect(ArtifactDetector.detect(language: "diff", code: String(repeating: "+ line\n", count: 80)) == nil)
        // An HTML fragment needs 1,200 characters and a tag.
        let fragment = "<section>" + String(repeating: "<p>Some words for the page.</p>", count: 40) + "</section>"
        #expect(ArtifactDetector.detect(language: "html", code: fragment)?.kind == .html)
    }

    @Test func longCodeIsAnArtifactNamedFromItsFile() {
        let code = "// server.ts\n" + (1...60).map { "const value\($0) = compute(\($0));" }.joined(separator: "\n")
        let detection = ArtifactDetector.detect(language: "TypeScript", code: code)
        #expect(detection?.kind == .code)
        #expect(detection?.title == "server.ts")
        #expect(detection?.language == "typescript")
        let swift = (["struct PricingCard: View {"] + (1...50).map { "    let row\($0) = \($0)" } + ["}"]).joined(separator: "\n")
        #expect(ArtifactDetector.detect(language: "swift", code: swift)?.title == "PricingCard")
    }

    @Test func theSameSlugInALaterReplyAddsAVersion() {
        let v1 = "```html\n\(pricingPage)\n```"
        let v2 = "```html\n\(pricingPage.replacingOccurrences(of: "$8", with: "$9"))\n```"
        let artifacts = Artifact.collect(from: [
            (turnID: "t1", text: v1, at: nil), (turnID: "t2", text: "No artifact here.", at: nil),
            (turnID: "t3", text: v2, at: nil), (turnID: "t4", text: v2, at: nil),
        ])
        #expect(artifacts.count == 1)
        #expect(artifacts[0].versions.map(\.turnID) == ["t1", "t3"]) // the repeat isn't a version
        #expect(artifacts[0].latest.content.contains("$9"))
    }

    @Test func repliesLoseTheirArtifactFencesButKeepOtherCode() {
        let reply = "Here it is:\n\n```html\n\(pricingPage)\n```\n\nRun it with:\n\n```sh\nopen index.html\n```"
        let lifted = ArtifactDetector.liftingArtifacts(from: reply)
        #expect(lifted.artifacts.count == 1)
        #expect(!lifted.text.contains("<!doctype"))
        #expect(lifted.text.contains("```sh\nopen index.html\n```"))
        #expect(lifted.text.hasPrefix("Here it is:"))
        let plain = "No code here."
        #expect(ArtifactDetector.liftingArtifacts(from: plain).text == plain)
        // Still streaming: the open fence stays.
        let streaming = "```html\n" + pricingPage
        #expect(ArtifactDetector.liftingArtifacts(from: streaming).text == streaming)
    }

    @Test func fencesWithTildesAndLongerRunsAreFound() {
        let text = "~~~~html\n\(pricingPage)\n~~~~\n````swift\nlet x = 1\n````"
        let fences = ArtifactDetector.fences(in: text)
        #expect(fences.count == 2)
        #expect(fences[0].language == "html")
        #expect(ArtifactDetector.hash("abc") == ArtifactDetector.hash("abc"))
        #expect(ArtifactDetector.hash("abc") != ArtifactDetector.hash("abd"))
    }

    // MARK: Preview

    @Test func previewTargetsKnowLocalhostAndFiles() {
        let local = PreviewTarget("localhost:5173/beta")
        #expect(local.isLocalhost)
        #expect(local.displayURL == "localhost:5173/beta")
        #expect(local.url?.absoluteString == "http://localhost:5173/beta")
        #expect(local.rewritten(toHost: "studio-mac.tail1234.ts.net")?.absoluteString == "http://studio-mac.tail1234.ts.net:5173/beta")
        #expect(PreviewTarget("http://127.0.0.1:3000").isLocalhost)
        let web = PreviewTarget("hermesapp.dev/pricing")
        #expect(!web.isLocalhost && web.url?.scheme == "https")
        #expect(web.rewritten(toHost: "x") == nil)
        if case .gatewayFile(let path) = PreviewTarget("/Users/studio/Code/site/index.html").kind {
            #expect(path == "/Users/studio/Code/site/index.html")
        } else {
            Issue.record("a path is a gateway file")
        }
        #expect(local.matches("http://localhost:5173/beta"))
        #expect(local.matches("localhost:5173"))
        #expect(!local.matches("localhost:3000"))
    }

    @Test func previewActionsAndAnswers() throws {
        let action = try #require(PreviewAction(params: try json(#"{"session_id": "s", "action": "type", "ref": "input-email", "text": "ada@example.com", "submit": true}"#)))
        #expect(action.verb == .type && action.ref == "input-email" && action.submit && action.actsOnElement)
        #expect(action.engineArguments.contains("\"kind\":\"type\""))
        #expect(PreviewAction(params: try json(#"{"action": "teleport"}"#)) == nil)
        let read = PreviewBridge.readAnswer(kind: "browser", url: "http://localhost:5173/beta", title: "Beta", text: "Your agent, in your pocket.", start: 5, count: 5)
        let value = try #require(read["value"]?.stringValue)
        let decoded = try json(value)
        #expect(decoded["text"]?.stringValue == "agent")
        #expect(decoded["start"]?.doubleValue == 5 && decoded["end"]?.doubleValue == 10)
        #expect(decoded["total_chars"]?.doubleValue == 27)
    }

    // MARK: RFB

    @Test func rfbHandshakeAndFrames() {
        let decoder = RFBDecoder()
        #expect(decoder.feed(Data("RFB 003.008\n".utf8)) == [.send(Data("RFB 003.008\n".utf8))])
        #expect(decoder.feed(Data([2, 2, 1])) == [.send(Data([1]))]) // VNC auth and None offered: None
        #expect(decoder.feed(Data([0, 0, 0, 0])) == [.send(Data([1]))]) // OK, then ClientInit
        var serverInit = Data([0, 4, 0, 2]) // 4 × 2
        serverInit.append(Data(repeating: 0, count: 16))
        serverInit.append(contentsOf: [0, 0, 0, 3])
        serverInit.append(Data("bot".utf8))
        let ready = decoder.feed(serverInit)
        #expect(ready.first == .ready(width: 4, height: 2, name: "bot"))
        #expect(ready.contains(.send(RFBMessages.updateRequest(incremental: false, width: 4, height: 2))))

        // One raw 2 × 1 rectangle, split across two frames, then a copy.
        var update = Data([0, 0, 0, 2])
        update.append(contentsOf: [0, 1, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0]) // x 1, y 0, 2 × 1, raw
        update.append(contentsOf: [10, 20, 30, 0, 40, 50, 60, 0])
        update.append(contentsOf: [0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0]) // copy to (0,1) from (1,0)
        #expect(decoder.feed(update.prefix(10)).isEmpty)
        let events = decoder.feed(update.dropFirst(10))
        var framebuffer = RFBFramebuffer()
        framebuffer.apply(ready[0])
        for event in events { framebuffer.apply(event) }
        #expect(events.contains(.updateDone))
        #expect(Array(framebuffer.pixels[4..<8]) == [10, 20, 30, 255])
        #expect(Array(framebuffer.pixels[16..<24]) == [10, 20, 30, 255, 40, 50, 60, 255]) // copied into row 1
    }

    @Test func rfbRefusalsReadAsReasons() {
        let decoder = RFBDecoder()
        _ = decoder.feed(Data("RFB 003.008\n".utf8))
        let events = decoder.feed(Data([1, 2])) // only VNC auth
        #expect(events.count == 1)
        if case .failed = events[0] {} else { Issue.record("expected a failure") }
        #expect(RFBMessages.pointer(x: 300, y: 2, buttons: 1) == Data([5, 1, 1, 44, 0, 2]))
        #expect(RFBMessages.key(0xFF0D, down: true) == Data([4, 1, 0, 0, 0, 0, 0xFF, 0x0D]))
        #expect(RFBMessages.keysym(for: "a") == 0x61)
        #expect(RFBMessages.keysym(for: "\n") == 0xFF0D)
    }

    // MARK: Files and changes

    @Test func readsListingsTreesAndReviews() throws {
        let listing = WorkspaceListing(json: try json(#"{"entries": [{"name": "src", "path": "/r/src", "isDirectory": true}, {"name": "README.md", "path": "/r/README.md", "isDirectory": false}]}"#))
        #expect(listing.entries.map(\.name) == ["src", "README.md"] && listing.entries[0].isDirectory)
        #expect(WorkspaceListing(json: try json(#"{"entries": [], "error": "EACCES"}"#)).error == "EACCES")
        let tree = try #require(GitWorkingTree(json: try json(#"{"branch": "feature/beta-page", "ahead": 2, "changed": 2, "files": [{"path": "src/pages/Beta.tsx", "staged": true, "unstaged": false, "untracked": false, "conflicted": false}, {"path": "src/components/BetaForm.tsx", "staged": false, "unstaged": true, "untracked": true, "conflicted": false}]}"#)))
        #expect(tree.branch == "feature/beta-page" && tree.file("src/components/BetaForm.tsx")?.letter == "A")
        #expect(GitWorkingTree(json: .null) == nil)
        let review = ReviewList(json: try json(#"{"files": [{"path": "a.ts", "added": 38, "removed": 6, "status": "M", "staged": true}, {"path": "b.ts", "added": 92, "removed": 0, "status": "?", "staged": false}], "base": "4be1c9a"}"#))
        #expect(review.added == 130 && review.removed == 6 && review.base == "4be1c9a")
        #expect(review.files[1].letter == "A")
        let text = WorkspaceText(json: try json(#"{"path": "/r/a.ts", "text": "let a = 1", "language": "typescript", "mimeType": "text/typescript", "byteSize": 9, "truncated": false, "binary": false}"#), path: "/r/a.ts")
        #expect(text.language == "typescript" && text.byteSize == 9)
    }
}
