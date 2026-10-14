import Foundation
import Testing
@testable import HermesKit

@Suite("Server-Sent Events parser")
struct ServerSentEventParserTests {
    private func parse(_ text: String, chunkSize: Int = .max) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        let bytes = Array(text.utf8)
        var events: [ServerSentEvent] = []
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + chunkSize)
            events += parser.consume(bytes[start..<end])
            start = end
        }
        return events
    }

    @Test func namedEventsAndDefaultType() {
        let events = parse("event: assistant.delta\ndata: {\"delta\":\"Hi\"}\n\ndata: plain\n\n")
        #expect(events == [
            ServerSentEvent(event: "assistant.delta", data: #"{"delta":"Hi"}"#),
            ServerSentEvent(event: "message", data: "plain"),
        ])
    }

    @Test func ignoresKeepaliveComments() {
        let events = parse(": keepalive\n\n: keepalive\n\ndata: x\n\n")
        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test func joinsMultipleDataLines() {
        #expect(parse("data: a\ndata: b\n\n") == [ServerSentEvent(data: "a\nb")])
    }

    @Test(arguments: ["\r\n", "\r", "\n"])
    func supportsEveryLineEnding(_ newline: String) {
        let text = "event: e" + newline + "data: 1" + newline + newline + "data: 2" + newline + newline
        #expect(parse(text) == [ServerSentEvent(event: "e", data: "1"), ServerSentEvent(data: "2")])
    }

    @Test func survivesArbitraryChunkingIncludingSplitUTF8AndCRLF() {
        let text = "event: assistant.delta\r\ndata: {\"delta\":\"héllo 👋\"}\r\n\r\n"
        for size in 1...7 {
            #expect(parse(text, chunkSize: size) == [ServerSentEvent(event: "assistant.delta", data: #"{"delta":"héllo 👋"}"#)])
        }
    }

    @Test func doesNotDispatchIncompleteTrailingEvent() {
        #expect(parse("data: unfinished\n").isEmpty)
    }

    @Test func fieldWithoutSpaceAndEmptyData() {
        #expect(parse("data:tight\n\ndata\n\n") == [ServerSentEvent(data: "tight"), ServerSentEvent(data: "")])
    }

    @Test func eventTypeResetsBetweenEvents() {
        let events = parse("event: a\ndata: 1\n\ndata: 2\n\n")
        #expect(events.map(\.event) == ["a", "message"])
    }

    @Test func stripsLeadingByteOrderMark() {
        #expect(parse("\u{FEFF}data: x\n\n") == [ServerSentEvent(data: "x")])
    }
}
