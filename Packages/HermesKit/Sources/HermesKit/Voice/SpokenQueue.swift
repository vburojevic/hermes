import HermesMarkdown

/// Where the player is in what it reads (`docs/voice.md` §3, §4.2): the sentences queued, the one
/// being heard, how many have been heard, and which one the voice is asked for next. The voice is
/// asked a couple of sentences ahead of the one being heard, never further, so a reply stopped
/// halfway costs nothing more.
///
/// A call's player reads every reply of the call one after another in one queue. Between two
/// replies it has caught up and hears nothing, and reading goes on from the first sentence not
/// yet heard, never from the start of the queue: a second reply used to wait for a sentence
/// that would never come and was never read.
public struct SpokenQueue: Sendable {
    public private(set) var sentences: [SpokenSentence] = []
    /// The sentence being heard; `nil` before the first and when it has caught up.
    public private(set) var current: Int?
    /// The next sentence to ask the voice for.
    public private(set) var nextToFetch = 0
    /// Sentences heard to their end.
    public private(set) var heard = 0
    /// Sentences fetched ahead of the one being heard.
    public let lookahead: Int

    public init(lookahead: Int = 2) {
        self.lookahead = lookahead
    }

    /// Everything queued has been asked for.
    public var isFetched: Bool { nextToFetch >= sentences.count }

    public mutating func append(_ more: [SpokenSentence]) {
        sentences += more
    }

    /// The sentence to ask the voice for now, if one is within reach of the one being heard (or,
    /// with nothing playing, of the first not heard yet). It counts as asked for.
    public mutating func takeNextToFetch() -> Int? {
        guard nextToFetch < sentences.count, nextToFetch <= (current ?? heard) + lookahead else { return nil }
        defer { nextToFetch += 1 }
        return nextToFetch
    }

    /// The sentence started to be heard. Returns whether it wasn't already.
    public mutating func begin(_ index: Int) -> Bool {
        guard current != index else { return false }
        current = index
        return true
    }

    /// The sentence being heard ended. Returns the one heard next when it's on its way already;
    /// `nil` when the player has caught up (a reply still being written, or the end).
    public mutating func ended(_ index: Int) -> Int? {
        guard current == index else { return nil }
        heard = index + 1
        if index + 1 < nextToFetch {
            current = index + 1
            return index + 1
        }
        current = nil
        return nil
    }

    /// Forgets everything queued (a stop).
    public mutating func reset() {
        self = SpokenQueue(lookahead: lookahead)
    }
}
