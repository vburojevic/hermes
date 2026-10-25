import HermesMarkdown
import Testing
@testable import HermesKit

@Suite("What the player reads next")
struct SpokenQueueTests {
    private func sentences(_ count: Int, from start: Int = 0) -> [SpokenSentence] {
        (start..<start + count).map { SpokenSentence(text: "Sentence \($0).", block: 0, range: 0..<0) }
    }

    /// Every sentence the voice is asked for now.
    private func fetchAll(_ queue: inout SpokenQueue) -> [Int] {
        var asked: [Int] = []
        while let index = queue.takeNextToFetch() { asked.append(index) }
        return asked
    }

    /// Fetches what's in reach, hears each fetched sentence to its end, and returns the order heard.
    private func readToTheEnd(_ queue: inout SpokenQueue) -> [Int] {
        var heard: [Int] = []
        var fetched: [Int] = []
        while true {
            while let index = queue.takeNextToFetch() { fetched.append(index) }
            if queue.current == nil {
                guard let first = fetched.first(where: { $0 >= queue.heard }) else { return heard }
                _ = queue.begin(first)
            }
            guard let playing = queue.current else { return heard }
            heard.append(playing)
            _ = queue.ended(playing)
        }
    }

    @Test func asksAheadOfTheSentenceHeardAndNoFurther() {
        var queue = SpokenQueue(lookahead: 2)
        queue.append(sentences(6))
        #expect(fetchAll(&queue) == [0, 1, 2])
        let began = queue.begin(0)
        let beganAgain = queue.begin(0)
        #expect(began && !beganAgain)
        let next = queue.ended(0)
        #expect(next == 1)
        #expect(fetchAll(&queue) == [3])
    }

    @Test func aSecondReplyIsReadAfterTheFirstWasHeardToItsEnd() {
        // A call reads every reply in one queue: the second starts at sentence 8.
        var queue = SpokenQueue()
        queue.append(sentences(8))
        #expect(readToTheEnd(&queue) == Array(0..<8))
        #expect(queue.current == nil)
        #expect(queue.isFetched)

        queue.append(sentences(5, from: 8))
        let first = queue.takeNextToFetch()
        #expect(first == 8, "the second reply was never asked for")
        _ = queue.begin(8)
        _ = queue.ended(8)
        #expect(readToTheEnd(&queue) == Array(9..<13))
        #expect(queue.isFetched)
    }

    @Test func aReplyStillBeingWrittenGoesOnAfterThePlayerCaughtUp() {
        // The voice reads faster than the reply streams: it catches up at sentence 5, then more come.
        var queue = SpokenQueue()
        queue.append(sentences(5))
        #expect(readToTheEnd(&queue) == Array(0..<5))
        queue.append(sentences(3, from: 5))
        #expect(readToTheEnd(&queue) == [5, 6, 7])
    }

    @Test func aStopForgetsWhatWasQueued() {
        var queue = SpokenQueue()
        queue.append(sentences(9))
        _ = readToTheEnd(&queue)
        queue.reset()
        #expect(queue.sentences.isEmpty)
        queue.append(sentences(2))
        #expect(fetchAll(&queue) == [0, 1])
    }

    @Test func aSentenceThatNeverPlaysDoesNotRunAhead() {
        // No player (nothing begins): the voice is asked for the lookahead's worth, then waits.
        var queue = SpokenQueue(lookahead: 2)
        queue.append(sentences(4))
        _ = readToTheEnd(&queue)
        queue.append(sentences(10, from: 4))
        #expect(fetchAll(&queue) == [4, 5, 6])
    }
}
