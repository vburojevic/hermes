import Foundation

/// Whether the session saying it's idle (`session.info` with `running: false`) ends the turn on
/// screen. Hermes says it whenever it sends the session's info, and it sends it while it builds a
/// chat's agent, before it takes a prompt (tui_gateway `_announce_built_agent`; the turn is only
/// marked running once taken). Ending the turn then emptied it: the thinking went, nothing came
/// in its place, and the turn's first events were dropped while it ended. So a prompt sent from
/// here counts only once Hermes has taken it: its submit answered, or an event of its turn came.
public struct TurnSettleGate: Sendable, Equatable {
    /// A prompt went out, or a turn is under way here.
    public private(set) var sent = false
    /// Hermes has taken it: an idle session now means the turn is over.
    public private(set) var taken = false

    public init() {}

    /// A prompt is going out: not taken until Hermes says so.
    public mutating func send() {
        sent = true
        taken = false
    }

    /// Hermes answered the submit, or an event of the turn came (a turn started elsewhere too).
    public mutating func take() {
        sent = true
        taken = true
    }

    /// The idle notice ends the turn.
    public var settles: Bool { sent && taken }
}
