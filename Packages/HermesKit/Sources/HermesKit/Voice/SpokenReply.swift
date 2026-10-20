import Foundation
import HermesMarkdown

/// Which reply Talk reads, and how much of it has been read (`docs/voice.md` §11): the first
/// assistant turn that wasn't in the chat when the spoken message went, followed by id. A reply
/// that was already there is never read again (a message queued behind a finishing turn used to
/// re-read the previous answer), and a later turn never takes over from the one being read.
public struct SpokenReplyTracker: Sendable {
    private let earlier: Set<String>
    public private(set) var trackedTurnID: String?
    public private(set) var isDone = false
    private var stream: SpokenStream

    /// - Parameter earlierTurnIDs: the assistant turns in the chat when the spoken message was sent.
    public init(earlierTurnIDs: Set<String>, detail: SpokenDetail = .describe, descriptions: SpokenDescriptions = .english) {
        earlier = earlierTurnIDs
        stream = SpokenStream(detail: detail, descriptions: descriptions)
    }

    /// The chat's newest assistant turn changed. Returns the sentences now ready to be spoken.
    /// - Parameter failure: the turn's error, read when it failed without an answer.
    /// - Parameter settled: the turn being read finished and left the live view: `turnID` is
    ///   the stored row it became (a new id for the same reply), so reading goes on.
    public mutating func update(turnID: String, answer: String, isFinished: Bool, failure: String? = nil, settled: Bool = false) -> [SpokenSentence] {
        guard !isDone, !earlier.contains(turnID) else { return [] }
        if let trackedTurnID, trackedTurnID != turnID, settled, trackedTurnID.hasPrefix("live-") {
            self.trackedTurnID = turnID
        } else if let trackedTurnID, trackedTurnID != turnID {
            // A newer turn (a queued message's) started: the one being read is over.
            isDone = true
            return []
        }
        trackedTurnID = turnID
        var ready = stream.update(answer, isFinished: isFinished)
        if isFinished {
            isDone = true
            if ready.isEmpty, answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let failure, !failure.isEmpty {
                ready.append(SpokenSentence(text: failure, block: 0, range: 0..<0))
            }
        }
        return ready
    }
}
