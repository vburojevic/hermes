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
        /// The message as sent from here, when there's more to it than its words.
        public var item: Item?
        /// Words only, nothing attached: Hermes may join it into the head envelope.
        public var isTextOnly: Bool
        /// Sent from this device; false for Hermes's head, sent from another device.
        public var isOwn: Bool

        public init(line: String, item: Item?, isTextOnly: Bool = true, isOwn: Bool = true) {
            self.line = line
            self.item = item
            self.isTextOnly = isTextOnly
            self.isOwn = isOwn
        }
    }

    /// Hermes's envelopes, in the order it sends them; each one turn.
    public private(set) var envelopes: [[Entry]] = [] {
        didSet { if envelopes.isEmpty { after = nil } }
    }
    /// The newest stored message before the turn the tray's first message waited behind: what
    /// happened to the tray while this device was away is in the stored chat past it (`Dropped`).
    public private(set) var after: Int?

    public init() {}

    public var entries: [Entry] { envelopes.flatMap { $0 } }
    public var lines: [String] { entries.map(\.line) }
    public var isEmpty: Bool { envelopes.isEmpty }

    /// Hermes took this device's message into its queue, joined to the head as Hermes joins it, or
    /// as an envelope of its own. `after`: the newest stored message before the turn it waits
    /// behind; the tray keeps its first own message's.
    public mutating func hold(_ line: String, item: Item?, isTextOnly: Bool = true, after: Int? = nil) {
        if !entries.contains(where: \.isOwn) { self.after = after }
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
        return purged().filter { !Self.take($0.line, from: &ran) }
    }

    /// Attached again (`session.resume`): `head` is the first message Hermes still holds, or nil.
    /// With nothing held, the tray empties and what it had comes back as `Dropped`: it ran while
    /// this device was away, or Hermes let the chat go (and its queue with it) before it could,
    /// and only the stored chat says which. Otherwise the messages this device sent stay (Hermes
    /// shows only the first, in its own words: a photo's message, a file's `@file:` line), and
    /// with none of its own the tray shows Hermes's head, sent from another device.
    @discardableResult
    public mutating func attached(head: String?) -> Dropped? {
        guard let head else {
            guard !envelopes.isEmpty else { return nil }
            let dropped = Dropped(entries: entries, after: after)
            envelopes = []
            return dropped
        }
        if envelopes.isEmpty { envelopes = [[Entry(line: head, item: nil, isOwn: false)]] }
        return nil
    }

    /// What the tray held when an attach found Hermes holding nothing (`attached(head:)`). Hermes
    /// lets a chat go about 20 s after its last socket closes (hermes-agent `tui_gateway`
    /// `_close_sessions_for_transport`, the WS-orphan reap), and the next `session.resume` retires
    /// the rows of messages its queue never sent (`retire_undrained_queue_rows`): those messages
    /// are gone from Hermes, and this device's copy is the only one left.
    public struct Dropped {
        public let entries: [Entry]
        /// The newest stored message before the turn they waited behind.
        public let after: Int?

        public struct GivenBack {
            public let entry: Entry
            /// Its waiting row is still stored, or the chat couldn't be read: Hermes may yet have it.
            public let maybeSent: Bool
        }

        /// Read against the stored chat (`stored`, nil when it couldn't be read): a message whose
        /// own turn started (a row of its own, not the one Hermes keeps while it waits) ran, and
        /// isn't given back to run again; one whose waiting row is still stored comes back Maybe
        /// sent; the rest never ran and come back Not sent. In order, each with this device's whole
        /// message. Hermes's head, sent from another device, isn't given back here: the device
        /// that sent it keeps its own copy.
        public func givenBack(stored: [SessionMessage]?) -> [GivenBack] {
            let own = entries.filter(\.isOwn)
            guard let stored else { return own.map { GivenBack(entry: $0, maybeSent: true) } }
            // A hidden row is nobody's turn (a row Hermes set aside, a summary): it says nothing ran.
            let since = stored.filter { $0.role == "user" && $0.displayKind != "hidden" && ($0.id ?? 0) > (after ?? -1) }
            // The turn they waited behind stored its own message first: it isn't one of theirs.
            let rows = since.firstIndex { !$0.isWaitingInQueue }.map { Array(since[since.index(after: $0)...]) } ?? since
            var ran = rows.filter { !$0.isWaitingInQueue }.map { GatewayHeldQueue.words($0.content.text) }
            var waiting = rows.filter(\.isWaitingInQueue).map { GatewayHeldQueue.words($0.content.text) }
            return own.compactMap { entry in
                if GatewayHeldQueue.take(entry.line, from: &ran) { return nil }
                return GivenBack(entry: entry, maybeSent: GatewayHeldQueue.take(entry.line, from: &waiting))
            }
        }
    }

    /// Words only: Hermes joins messages with blank lines and the tray collapses them.
    static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether `line` is in one of the stored `rows` (words only); if so, its words leave that row.
    /// Hermes runs text-only messages it joined as one turn (one row), so each of them is found
    /// in it, once.
    static func take(_ line: String, from rows: inout [String]) -> Bool {
        let words = words(line)
        guard !words.isEmpty else { return false }
        for index in rows.indices {
            guard let range = rows[index].range(of: words) else { continue }
            rows[index].removeSubrange(range)
            return true
        }
        return false
    }
}

extension GatewayHeldQueue: Sendable where Item: Sendable {}
extension GatewayHeldQueue.Entry: Sendable where Item: Sendable {}
extension GatewayHeldQueue.Dropped: Sendable where Item: Sendable {}
extension GatewayHeldQueue.Dropped.GivenBack: Sendable where Item: Sendable {}
