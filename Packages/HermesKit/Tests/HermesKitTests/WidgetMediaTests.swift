import Foundation
import Testing
@testable import HermesKit

@Suite struct WidgetMediaTests {
    private func widget(_ kinds: [String]) throws -> MediaWidget {
        let items = kinds.enumerated().map { index, kind in
            #"{"media": {"src": "hermes-file:/m/\#(index).\#(kind == "video" ? "mp4" : kind == "audio" ? "m4a" : "jpg")", "alt": "Item \#(index)", "kind": "\#(kind)"}}"#
        }
        let json = #"{"items": [\#(items.joined(separator: ","))]}"#
        return try JSONDecoder().decode(MediaWidget.self, from: Data(json.utf8))
    }

    @Test func typesComeFromTheExtension() throws {
        #expect(MediaFileType(path: "/home/me/Ilica/balcony.JPG")?.kind == .picture)
        #expect(MediaFileType(path: "/home/me/Ilica/balcony.JPG")?.uniformType == "public.jpeg")
        #expect(MediaFileType(path: "hermes-file:/m/walk.mp4")?.mimeType == "video/mp4")
        #expect(MediaFileType(path: "clip.mov")?.uniformType == "com.apple.quicktime-movie")
        #expect(MediaFileType(path: "pic.webp")?.name == "WebP")
    }

    @Test func unknownAndRefusedSuffixesAreNotMedia() {
        // Hermes answers 415 for m4v and mkv, so they never open as video.
        #expect(MediaFileType(path: "clip.m4v") == nil)
        #expect(MediaFileType(path: "clip.mkv") == nil)
        #expect(MediaFileType(path: "notes.txt") == nil)
        #expect(MediaFileType(path: ".jpg") == nil)
        #expect(MediaFileType(path: "folder.jpg/readme") == nil)
        #expect(MediaFileType(path: "noextension") == nil)
    }

    @Test func typesComeFromAContentType() {
        #expect(MediaFileType(mimeType: "video/quicktime")?.name == "QuickTime video")
        #expect(MediaFileType(mimeType: "Image/PNG; charset=binary")?.kind == .picture)
        #expect(MediaFileType(mimeType: "application/octet-stream") == nil)
    }

    @Test func voiceNotesStayOutOfTheViewer() throws {
        let card = try widget(["image", "audio", "video", "image"])
        #expect(MediaViewing.items(of: card).map(\.media.kind) == [.image, .video, .image])
        #expect(MediaViewing.startPage(tapping: 2, in: card) == 1)
        #expect(MediaViewing.startPage(tapping: 3, in: card) == 2)
    }

    @Test func theMoreTileOpensAtTheFirstHiddenItem() throws {
        let card = try widget(Array(repeating: "image", count: 12))
        #expect(MediaViewing.startPage(tapping: 3, in: card) == 3)
        #expect(MediaViewing.startPage(tapping: 3, in: card, moreTile: true) == 4)
        #expect(MediaViewing.startPage(tapping: 40, in: card) == 0)
    }

    @Test func positionIsShownOnlyForMoreThanOneItem() {
        #expect(MediaViewing.position(3, of: 12)?.current == 4)
        #expect(MediaViewing.position(3, of: 12)?.total == 12)
        #expect(MediaViewing.position(0, of: 1) == nil)
        #expect(MediaViewing.position(12, of: 12) == nil)
    }

    @Test func clockReadsLikeAPlayer() {
        #expect(MediaViewing.clock(42) == "0:42")
        #expect(MediaViewing.clock(41.6) == "0:42")
        #expect(MediaViewing.clock(725) == "12:05")
        #expect(MediaViewing.clock(3729) == "1:02:09")
        #expect(MediaViewing.clock(-3) == "0:00")
    }

    @Test func summaryLeavesOutWhatIsNotKnown() throws {
        let locale = Locale(identifier: "en_US")
        let jpeg = try #require(MediaFileType(path: "a.jpg"))
        let mp4 = try #require(MediaFileType(path: "a.mp4"))
        #expect(MediaViewing.summary(jpeg, width: 4032, height: 3024, duration: nil, bytes: 3_100_000, locale: locale)
            == "JPEG · 4,032 × 3,024 · 3.1 MB")
        #expect(MediaViewing.summary(mp4, width: 1920, height: 1080, duration: 42, bytes: 18_400_000, locale: locale)
            == "MPEG-4 video · 1,920 × 1,080 · 0:42 · 18.4 MB")
        #expect(MediaViewing.summary(jpeg, width: nil, height: nil, duration: 9, bytes: nil, locale: locale) == "JPEG")
    }

    @Test func rangesCountBothEndsLikeHTTP() {
        #expect(ByteRange(offset: 100, length: 1_000)?.header == "bytes=100-1099")
        #expect(ByteRange(offset: 100, length: 1_000)?.length == 1_000)
        #expect(ByteRange(offset: 0, length: 0) == nil)
        #expect(ByteRange(offset: 0, length: 2)?.header == "bytes=0-1")
        #expect(ByteRange(offset: -1, length: 2) == nil)
    }

    @Test func contentRangeIsRead() throws {
        let range = try #require(ContentRange(header: "bytes 0-1023/52428800"))
        #expect(range.start == 0 && range.end == 1023 && range.total == 52_428_800)
        #expect(ContentRange(header: "bytes 10-19/*")?.total == nil)
        #expect(ContentRange(header: "bytes */100") == nil)
        #expect(ContentRange(header: "bytes 10-5/100") == nil)
        #expect(ContentRange(header: "bytes 0-100/100") == nil)
        #expect(ContentRange(header: "items 0-1/2") == nil)
    }

    private func answer(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: URL(string: "http://127.0.0.1/api/files/stream")!, statusCode: status,
                                     httpVersion: "HTTP/1.1", headerFields: headers))
    }

    @Test func aPartialAnswerIsReadByItsContentRange() throws {
        let asked = try #require(ByteRange(offset: 1_000, length: 4))
        let response = try answer(206, ["Content-Range": "bytes 1000-1003/9000", "Content-Type": "video/mp4"])
        let range = GatewayFileRange(asked: asked, data: Data([1, 2, 3, 4]), response: response)
        #expect(range.start == 1_000 && range.total == 9_000 && range.data.count == 4)
        #expect(range.contentType == "video/mp4")
    }

    @Test func aWholeAnswerIsSlicedToTheStretchAsked() throws {
        let whole = Data((0..<10).map { UInt8($0) })
        let middle = GatewayFileRange(asked: try #require(ByteRange(offset: 2, length: 3)), data: whole, response: try answer(200, [:]))
        #expect(middle.data == Data([2, 3, 4]) && middle.start == 2 && middle.total == 10)
        let past = GatewayFileRange(asked: try #require(ByteRange(offset: 8, length: 5)), data: whole, response: try answer(200, [:]))
        #expect(past.data == Data([8, 9]))
        let beyond = GatewayFileRange(asked: try #require(ByteRange(offset: 20, length: 5)), data: whole, response: try answer(200, [:]))
        #expect(beyond.data.isEmpty && beyond.start == 10)
    }

    @Test func problemsReadLikeTheDesignStates() {
        #expect(MediaProblem.of(BackendClient.Failure.http(404, "File not found"), video: false) == .gone)
        #expect(MediaProblem.of(RemotePicture.Failure.status(404), video: true) == .gone)
        #expect(MediaProblem.of(BackendClient.Failure.http(403, "Access to sensitive files is not allowed"), video: true) == .notAllowed)
        #expect(MediaProblem.of(MediaTooBig(bytes: 64_000_000), video: false) == .tooBig(bytes: 64_000_000))
        #expect(MediaProblem.of(URLError(.timedOut), video: false) == .couldntLoad)
        #expect(MediaProblem.of(URLError(.networkConnectionLost), video: true) == .couldntPlay)
    }

    @Test func aMissingProfileOrRouteIsNotAGoneFile() {
        #expect(MediaProblem.of(BackendClient.Failure.http(404, "Profile 'x' does not exist."), video: false) == .couldntLoad)
        #expect(MediaProblem.of(BackendClient.Failure.http(404, "No such API endpoint"), video: true) == .couldntPlay)
        #expect(MediaProblem.of(BackendClient.Failure.http(415, "Unsupported media type"), video: true) == .couldntPlay)
    }

    private func stubbed(_ host: String, _ handler: @escaping @Sendable (URLRequest) -> StubProtocol.Response) -> URLSession {
        StubProtocol.lock.withLock { StubProtocol.routes[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func anHttpsVideoIsReadAStretchAtATime() async throws {
        let host = "range-206.example"
        defer { StubProtocol.removeRoute(host) }
        let session = stubbed(host) { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-7")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .init(status: 206, headers: ["Content-Range": "bytes 4-7/100", "Content-Type": "video/mp4"], body: Data([4, 5, 6, 7]))
        }
        let part = try await RemoteMedia.range(at: try #require(URL(string: "https://\(host)/clip.mp4")),
                                               range: try #require(ByteRange(offset: 4, length: 4)), in: session)
        #expect(part.start == 4 && part.total == 100 && part.data == Data([4, 5, 6, 7]))
    }

    @Test func aServerThatIgnoresRangeIsRefused() async throws {
        let host = "range-200.example"
        defer { StubProtocol.removeRoute(host) }
        let session = stubbed(host) { _ in .init(status: 200, headers: ["Content-Type": "video/mp4"], body: Data(count: 64)) }
        await #expect(throws: RemoteMedia.RangesIgnored.self) {
            try await RemoteMedia.range(at: try #require(URL(string: "https://\(host)/clip.mp4")),
                                        range: try #require(ByteRange(offset: 0, length: 2)), in: session)
        }
    }

    @Test func aCancelledReadIsACancelNotAFailure() async throws {
        let host = "range-cancelled.example"
        defer { StubProtocol.removeRoute(host) }
        let session = stubbed(host) { _ in .init(status: 0, body: Data(), error: .cancelled) }
        await #expect(throws: CancellationError.self) {
            try await RemoteMedia.range(at: try #require(URL(string: "https://\(host)/clip.mp4")),
                                        range: try #require(ByteRange(offset: 0, length: 2)), in: session)
        }
        #expect(RemoteMedia.isCancellation(URLError(.cancelled)))
        #expect(RemoteMedia.isCancellation(CancellationError()))
        #expect(!RemoteMedia.isCancellation(URLError(.networkConnectionLost)))
    }
}
