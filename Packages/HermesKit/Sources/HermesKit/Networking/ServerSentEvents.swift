import Foundation

/// One dispatched Server-Sent Event.
public struct ServerSentEvent: Sendable, Equatable {
    /// The `event:` field, or `"message"` when the stream did not name the event.
    public var event: String
    /// All `data:` lines of the event joined with `\n`.
    public var data: String
    /// The last `id:` seen on the stream, if any.
    public var lastEventID: String?

    public init(event: String = "message", data: String, lastEventID: String? = nil) {
        self.event = event
        self.data = data
        self.lastEventID = lastEventID
    }
}

/// Incremental parser for `text/event-stream`, following the WHATWG HTML
/// "event stream interpretation" rules.
///
/// Feed it raw bytes in any chunking. Lines may end in CRLF, LF or CR, comment
/// lines (`: keepalive`) are ignored, and an event is dispatched on a blank line.
/// `URLSession.AsyncBytes.lines` is deliberately not used: it drops the blank
/// lines that delimit events.
public struct ServerSentEventParser: Sendable {
    private var line: [UInt8] = []
    private var previousWasCR = false
    private var isAtStreamStart = true
    private var eventType = ""
    private var dataLines: [String] = []
    private var lastEventID: String?

    public init() {}

    /// Consumes one byte and returns an event when that byte completes one.
    public mutating func consume(_ byte: UInt8) -> ServerSentEvent? {
        switch byte {
        case 0x0A: // LF
            if previousWasCR {
                // Second half of a CRLF pair: the line already ended on CR.
                previousWasCR = false
                return nil
            }
            return endLine()
        case 0x0D: // CR
            previousWasCR = true
            return endLine()
        default:
            previousWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// Consumes a chunk and returns every event it completes, in order.
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in bytes {
            if let event = consume(byte) {
                events.append(event)
            }
        }
        return events
    }

    private mutating func endLine() -> ServerSentEvent? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if isAtStreamStart {
            isAtStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                bytes.removeFirst(3)
            }
        }
        if bytes.isEmpty {
            return dispatch()
        }
        if bytes.first == 0x3A { // ":" comment, e.g. keepalive
            return nil
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event":
            eventType = String(value)
        case "data":
            dataLines.append(String(value))
        case "id":
            if !value.contains("\0") {
                lastEventID = String(value)
            }
        default:
            // `retry` and unknown fields are irrelevant to a one-shot stream.
            break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventType = ""
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(
            event: eventType.isEmpty ? "message" : eventType,
            data: dataLines.joined(separator: "\n"),
            lastEventID: lastEventID
        )
    }
}
