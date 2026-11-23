import Foundation

/// Whether the gateway's Mac is busy: up, but too loaded to answer in time
/// (`docs/connecting-and-voice.md` §3). `BotWorkspace` keeps one for the gateway and `BotRoster`
/// one for Bot Mode; both read `isBusy` from it.
///
/// The person's own reply running is no sign. While one runs, Hermes holds a chat-list read until
/// the reply's token counts are written, up to 5 s (`flush_for_read` in `hermes_state_usage.py`),
/// and older Hermes froze its whole event loop for that long (#141966). So an answer that was slow
/// while the person's own turn ran, or just after it, counts for nothing either way. A health
/// check that goes unanswered always counts: a turn never holds that up for 15 s.
///
/// Busy clears by itself: once half a minute has passed since the last sign, and a quick answer
/// came after it (a starved Mac answers quickly for the moment it runs, then goes quiet again),
/// unless a request that counts is still out past `quickAnswer`. `clearsAt` says when to look.
public struct BusySignal: Sendable {
    /// A request the signal is timing.
    public struct Ticket: Hashable, Sendable {
        fileprivate let id: Int
    }

    /// Only an answer this quick counts as quick; a slower one is the busy Mac itself.
    public static let quickAnswer: Duration = .seconds(5)
    /// How long busy stays after the last sign.
    public static let lingers: Duration = .seconds(30)
    /// How long after the person's own turn ends its writes can still hold a read up.
    public static let turnAftermath: Duration = .seconds(5)

    public private(set) var isBusy = false

    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastSign: ContinuousClock.Instant?
    /// A quick answer came after the last sign.
    private var quickSinceSign = false
    private var ownTurnRunning = false
    private var ownTurnEndedAt: ContinuousClock.Instant?
    private var inFlight: [Int: Request] = [:]
    private var nextTicket = 0

    private struct Request {
        var began: ContinuousClock.Instant
        /// The person's own turn ran at some point while it was out (or had just ended).
        var duringOwnTurn: Bool
    }

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// When busy would clear if nothing else happens: nil while it isn't busy, while it waits for
    /// a quick answer, or while a request that counts is out and slow (its end settles it).
    public var clearsAt: ContinuousClock.Instant? {
        guard isBusy, quickSinceSign, let lastSign, !slowRequestOut else { return nil }
        return lastSign + Self.lingers
    }

    /// One of the person's own turns started or finished (any chat on this gateway or its Bots).
    public mutating func ownTurn(running: Bool) {
        guard running != ownTurnRunning else { return }
        ownTurnRunning = running
        if running {
            for key in inFlight.keys { inFlight[key]?.duringOwnTurn = true }
        } else {
            ownTurnEndedAt = now()
        }
    }

    /// A request went out.
    public mutating func began() -> Ticket {
        nextTicket += 1
        inFlight[nextTicket] = Request(began: now(), duringOwnTurn: ownTurnNear)
        return Ticket(id: nextTicket)
    }

    /// The request came back: quick, a quick answer; slow, a sign, unless the person's own turn
    /// explains it.
    public mutating func answered(_ ticket: Ticket) {
        guard let request = finish(ticket) else { return }
        if now() - request.began < Self.quickAnswer {
            quick()
        } else if !request.duringOwnTurn {
            sign()
        } else {
            settle()
        }
    }

    /// The request is still out after a while, with the gateway there: a sign, unless the person's
    /// own turn explains it.
    public mutating func stillRunning(_ ticket: Ticket) {
        guard let request = inFlight[ticket.id] else { return }
        if ownTurnNear { inFlight[ticket.id]?.duringOwnTurn = true }
        guard !request.duringOwnTurn, !ownTurnNear else { return }
        sign()
    }

    /// The request timed out with the gateway still there: a sign, unless the person's own turn
    /// explains it.
    public mutating func timedOut(_ ticket: Ticket) {
        guard let request = finish(ticket) else { return }
        if request.duringOwnTurn { settle() } else { sign() }
    }

    /// The request failed or was cancelled: it says nothing about the Mac.
    public mutating func ended(_ ticket: Ticket) {
        guard finish(ticket) != nil else { return }
        settle()
    }

    /// A sign that always counts: a health check left unanswered, a socket gone quiet.
    public mutating func sign() {
        lastSign = now()
        quickSinceSign = false
        isBusy = true
    }

    /// A quick answer timed elsewhere.
    public mutating func quick() {
        quickSinceSign = true
        settle()
    }

    /// The gateway answered with an error, or failed: whatever it is, it isn't busy.
    public mutating func reset() {
        lastSign = nil
        quickSinceSign = false
        isBusy = false
    }

    /// Clears busy if its time is up (call at `clearsAt`).
    public mutating func settle() {
        guard let clearsAt, now() >= clearsAt else { return }
        isBusy = false
    }

    /// A request out longer than a quick answer takes, with no turn of the person's to explain it.
    private var slowRequestOut: Bool {
        let current = now()
        return inFlight.values.contains {
            !$0.duringOwnTurn && current - $0.began >= Self.quickAnswer
        }
    }

    private var ownTurnNear: Bool {
        if ownTurnRunning { return true }
        guard let ownTurnEndedAt else { return false }
        return now() - ownTurnEndedAt < Self.turnAftermath
    }

    /// Takes the request off the list, noting whether the person's own turn is near as it ends.
    private mutating func finish(_ ticket: Ticket) -> Request? {
        guard var request = inFlight.removeValue(forKey: ticket.id) else { return nil }
        if ownTurnNear { request.duringOwnTurn = true }
        return request
    }
}

extension BusySignal {
    /// The chats whose own turn is running, for `ownTurn(running:)`. Held weakly, so a chat that
    /// goes away stops counting. A chat cut off mid-turn (deleted, discarded, disconnected) never
    /// says its turn ended, so it's forgotten instead.
    public struct OwnTurns<Chat: AnyObject> {
        private struct Entry {
            weak var chat: Chat?
        }

        private var chats: [ObjectIdentifier: Entry] = [:]

        public init() {}

        /// Whether any chat's own turn is still running.
        public var anyRunning: Bool { chats.values.contains { $0.chat != nil } }

        /// The chat's own turn started or ended.
        public mutating func set(_ chat: Chat, running: Bool) {
            chats[ObjectIdentifier(chat)] = running ? Entry(chat: chat) : nil
        }

        /// The chat stopped all its work: its turn, if one ran, no longer counts.
        public mutating func forget(_ chat: Chat) {
            chats[ObjectIdentifier(chat)] = nil
        }
    }
}
