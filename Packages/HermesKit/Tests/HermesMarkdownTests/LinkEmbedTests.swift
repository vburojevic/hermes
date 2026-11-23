import Foundation
import Testing
@testable import HermesMarkdown

/// A link that shows as a card (`docs/chat.md` §3d).
@Suite("Link embeds")
struct LinkEmbedTests {
    private func kind(_ address: String) -> LinkEmbed.Kind? { LinkEmbed(address: address)?.kind }
    private func block(_ markdown: String) -> MarkdownBlock? { MarkdownDocument(parsing: markdown).blocks.first }

    @Test func youtube() {
        #expect(kind("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42") == .video)
        #expect(kind("https://youtu.be/dQw4w9WgXcQ?si=abc") == .video)
        #expect(kind("https://m.youtube.com/watch?list=x&v=dQw4w9WgXcQ") == .video)
        #expect(kind("https://www.youtube.com/shorts/dQw4w9WgXcQ") == .short)
        #expect(kind("https://www.youtube.com/live/dQw4w9WgXcQ") == .live)
        #expect(kind("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ") == .video)
        #expect(kind("https://www.youtube.com/playlist?list=PLabcdefghij") == .playlist)
        #expect(kind("https://www.youtube.com/watch?v=short") == nil)
        #expect(kind("https://www.youtube.com/@someone") == nil)
        #expect(kind("https://www.youtube.com/") == nil)
    }

    @Test func musicAndVideo() {
        #expect(kind("https://vimeo.com/76979871") == .video)
        #expect(kind("https://vimeo.com/76979871/8272103f6e") == .video)
        #expect(kind("https://player.vimeo.com/video/76979871") == .video)
        #expect(kind("https://vimeo.com/features") == nil)
        #expect(kind("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=x") == .track)
        #expect(kind("https://open.spotify.com/intl-de/album/4cOdK2wGLETKBW3PvgPWqT") == .album)
        #expect(kind("https://open.spotify.com/playlist/4cOdK2wGLETKBW3PvgPWqT") == .playlist)
        #expect(kind("https://open.spotify.com/episode/4cOdK2wGLETKBW3PvgPWqT") == .episode)
        #expect(kind("https://open.spotify.com/track/tooshort") == nil)
        #expect(LinkEmbed(address: "https://soundcloud.com/forss/flickermood")?.name == "forss/flickermood")
        #expect(kind("https://soundcloud.com/forss/sets/soulhack") == .playlist)
        #expect(kind("https://soundcloud.com/forss/likes") == nil)
        #expect(kind("https://soundcloud.com/discover/new") == nil)
        #expect(LinkEmbed(address: "https://www.bilibili.com/video/BV1xx411c7mD/?p=2")?.name == "BV1xx411c7mD")
        #expect(kind("https://www.bilibili.com/video/av170001") == .video)
        #expect(kind("https://www.bilibili.com/read/cv1") == nil)
        // A short link says nothing about where it goes.
        #expect(kind("https://b23.tv/abc123") == nil)
    }

    @Test func github() {
        #expect(LinkEmbed(address: "https://github.com/NousResearch/hermes-agent")?.name == "NousResearch/hermes-agent")
        #expect(LinkEmbed(address: "https://github.com/a/b.git")?.name == "a/b")
        #expect(kind("https://github.com/a/b/issues/12#issuecomment-1") == .issue(12))
        #expect(kind("https://github.com/a/b/pull/7") == .pullRequest(7))
        #expect(kind("https://github.com/a/b/discussions/3") == .discussion(3))
        #expect(kind("https://github.com/a/b/blob/main/README.md") == nil)
        #expect(kind("https://github.com/a/b/pull/seven") == nil)
        #expect(kind("https://github.com/settings/profile") == nil)
        #expect(kind("https://github.com/a") == nil)
        #expect(kind("https://gist.github.com/a/b") == nil)
    }

    @Test func onlyTheServicesOwnAddress() {
        #expect(kind("http://github.com/a/b") == nil)
        #expect(kind("https://github.com.evil.example/a/b") == nil)
        #expect(kind("https://github.com@evil.example/a/b") == nil)
        #expect(kind("https://me@github.com/a/b") == nil)
        #expect(kind("https://github.com:8443/a/b") == nil)
        #expect(kind("https://evil.example/github.com/a") == nil)
        #expect(kind("https://github.com/a/b%E2%80%AEgpj") == nil)
        #expect(kind("https://github.com/a/..") == nil)
        #expect(kind("hermesapp://youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(kind("https://github.com/a/" + String(repeating: "b", count: 3000)) == nil)
    }

    @Test func onlyALinkAlone() throws {
        let bare = try #require(block("https://youtu.be/dQw4w9WgXcQ").flatMap { LinkEmbed($0) })
        #expect(bare.label == nil)
        let named = try #require(block("[The launch talk](https://youtu.be/dQw4w9WgXcQ)").flatMap { LinkEmbed($0) })
        #expect(named.label == "The launch talk")
        #expect(named.url.absoluteString == "https://youtu.be/dQw4w9WgXcQ")
        #expect(block("[github.com/a/b](https://github.com/a/b)").flatMap { LinkEmbed($0) }?.label == nil)
        #expect(block("See https://youtu.be/dQw4w9WgXcQ").flatMap { LinkEmbed($0) } == nil)
        #expect(block("https://youtu.be/dQw4w9WgXcQ https://github.com/a/b").flatMap { LinkEmbed($0) } == nil)
        #expect(block("`https://youtu.be/dQw4w9WgXcQ`").flatMap { LinkEmbed($0) } == nil)
        #expect(block("https://example.com/a").flatMap { LinkEmbed($0) } == nil)
        #expect(block("# https://github.com/a/b").flatMap { LinkEmbed($0) } == nil)
    }

    @Test func copiesAsTheLink() {
        let units = ReplyPlainText.units(MarkdownDocument(parsing: "Watch:\n\nhttps://youtu.be/dQw4w9WgXcQ\n\n- https://github.com/a/b").blocks)
        #expect(units.map(\.text) == ["Watch:", "https://youtu.be/dQw4w9WgXcQ", "https://github.com/a/b"])
        if case .block = units[1].content {} else { Issue.record("a card is a block of its own") }
        if case .paragraph = units[2].content {} else { Issue.record("a list keeps its links as words") }
    }
}
