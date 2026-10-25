import Foundation

/// The messages Hermes holds for the chat's next turns, as the Up Next tray shows them, read-only
/// (`docs/follow-ups.md`, `docs/chat.md` §4c): photos, files or a recording sent while a turn ran
/// (`prompt.submit {queued: true}`), a redirect or steer Hermes queued while it compacted, a message
/// it queued behind a turn this device hadn't seen. Each keeps the app's whole message, so one that
/// Hermes drops can be given back with its attachments.
///
/// What Hermes does with its queue (hermes-agent `tui_gateway/session_auto_continue.py`
/// `_enqueue_prompt`, `_drain_queued_prompt`; `session_lifecycle.py`):
/// - it keeps envelopes, a head and a tail. A text-only message joins the head
///   (`"{head}\n\n{text}"`) only while the head is text-only and nothing waits behind it; anything
///   with photos or files, or anything once the tail has started, is an envelope of its own;
/// - as each turn ends it sends one envelope, the head, as the next turn: the rest move up;
/// - Stop (`session.interrupt`) empties it: nothing in it runs;
/// - `session.resume` shows only the head (`queued: {user}`).
public struct GatewayHeldQueue<Item> {
    public struct Entry {
        /// The tray's line.
        public var line: String
        /// The message as sent from here; nil for one this device only heard of from Hermes.
        public var item: Item?
        /// Words only, nothing attached: Hermes may join it into the head envelope.
        public var isTextOnly: Bool

        public init(line: String, item: Item?, isTextOnly: Bool = true) {
            self.line = line
            self.item = item
            self.isTextOnly = isTextOnly
        }
    }

    /// Hermes's envelopes, in the order it sends them; each one turn.
    public private(set) var envelopes: [[Entry]] = []

    public init() {}

    public var entries: [Entry] { envelopes.flatMap { $0 } }
    public var lines: [String] { entries.map(\.line) }
    public var isEmpty: Bool { envelopes.isEmpty }

    /// Hermes took it into its queue, joined to the head as Hermes joins it, or as an envelope of its own.
    public mutating func hold(_ line: String, item: Item?, isTextOnly: Bool = true) {
        let entry = Entry(line: line, item: item, isTextOnly: isTextOnly)
        if isTextOnly, envelopes.count == 1, envelopes[0].allSatisfy(\.isTextOnly) {
            envelopes[0].append(entry)
        } else {
            envelopes.append([entry])
        }
    }

    /// It never reached Hermes's queue (its submit failed, or it started a turn of its own).
    @discardableResult
    public mutating func release(_ line: String) -> Entry? {
        for index in envelopes.indices {
            guard let at = envelopes[index].firstIndex(where: { $0.line == line }) else { continue }
            let entry = envelopes[index].remove(at: at)
            if envelopes[index].isEmpty { envelopes.remove(at: index) }
            return entry
        }
        return nil
    }

    /// A turn started from Hermes's queue: it carries the head envelope, and only that one leaves the
    /// tray. The rest stay held for the turns after it.
    @discardableResult
    public mutating func taken() -> [Entry] {
        envelopes.isEmpty ? [] : envelopes.removeFirst()
    }

    /// Everything goes from the tray at once (what it held has gone some other way).
    public mutating func removeAll() {
        envelopes = []
    }

    /// Stop emptied Hermes's queue: none of them will run. They come back, in order, with their
    /// attachments, for the person to send again.
    public mutating func purged() -> [Entry] {
        defer { envelopes = [] }
        return entries
    }

    /// Stop emptied Hermes's queue, read against the stored chat once the stopped turn settled: a
    /// message whose own turn had started (Hermes stores it then as a row of its own, not the row it
    /// keeps for a message waiting in its queue) ran, and isn't given back to run again; the rest
    /// never ran. `ranSince` is the person's stored messages since the stopped turn began.
    public mutating func purged(ranSince stored: [SessionMessage]) -> [Entry] {
        var ran = stored.filter { $0.role == "user" && !$0.isWaitingInQueue }.map { Self.words($0.content.text) }
        return purged().filter { entry in
            guard let index = ran.firstIndex(where: { $0.contains(Self.words(entry.line)) && !Self.words(entry.line).isEmpty }) else { return true }
            ran.remove(at: index)
            return false
        }
    }

    /// Attached again (`session.resume`): `head` is the first message Hermes still holds, or nil.
    /// With nothing held, what the tray had ran while this device was away, or went with a Stop
    /// elsewhere: the stored chat says which, so nothing is given back. Otherwise the messages this
    /// device sent stay (Hermes shows only the first, in its own words: a photo's message, a
    /// file's `@file:` line), and with none of its own the tray shows Hermes's head, sent from
    /// another device.
    public mutating func attached(head: String?) {
        guard let head else {
            envelopes = []
            return
        }
        if envelopes.isEmpty { envelopes = [[Entry(line: head, item: nil)]] }
    }

    /// Words only: Hermes joins messages with blank lines and the tray collapses them.
    static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension GatewayHeldQueue: Sendable where Item: Sendable {}
extension GatewayHeldQueue.Entry: Sendable where Item: Sendable {}
