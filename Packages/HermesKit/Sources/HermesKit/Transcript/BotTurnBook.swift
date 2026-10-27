import Foundation

/// What the Bots list keeps of each Bot Chat's last turn beyond the chat's own record
/// (`docs/bots-groups-skills.md` §1.2, `docs/chat.md` §2).
///
/// Two records, each owning one thing, so they can't contradict each other:
/// - **settled** lives in the chat's `KeptTurn` (`stoppedAt`), on the device across launches. The chat
///   writes it when it settles a turn; the Bots list writes the same record when it settles one no
///   chat followed, and reads it for every Bot. A Bot Chat shows "Stopped" from it, after a relaunch
///   too, and nothing shows that turn as working.
/// - **lost** lives here, in memory, for the Bots list alone: the roster couldn't find out how the
///   turn ended within `TurnRecovery`'s minute. Nothing shows it as working, the chat doesn't say
///   "Stopped", and the roster looks again. A relaunch forgets it, so the next launch looks again.
///
/// Both are known by the turn's last stored row: a row stored after it is the turn going on.
public struct BotTurnBook: Sendable, Equatable {
    private var lost: [String: Int] = [:]

    public init() {}

    /// The row to settle a turn at where these rows stop: nil when they don't stop mid-work, so a turn
    /// stored whole is never "Stopped".
    public static func stoppedRow(_ rows: [SessionMessage], now: Date = .now) -> Int? {
        guard TranscriptBuilder.endsMidTurn(rows, now: now) else { return nil }
        return TranscriptBuilder.lastTurnRowID(rows)
    }

    /// The roster lost track of the turn where these rows stop. Returns whether it marked it.
    @discardableResult
    public mutating func lose(_ name: String, rows: [SessionMessage], now: Date = .now) -> Bool {
        guard let row = Self.stoppedRow(rows, now: now) else { return false }
        lost[name] = row
        return true
    }

    /// Hermes answered for the turn after all (it runs, it settled, or its rows moved): the mark goes.
    public mutating func found(_ name: String) {
        lost[name] = nil
    }

    /// The roster lost track of the turn these rows end in.
    public func isLost(_ name: String, rows: [SessionMessage]) -> Bool {
        guard let row = lost[name] else { return false }
        return TranscriptBuilder.lastTurnRowID(rows) == row
    }

    /// What the Bot's row shows from its Bot Chat's stored rows: the turn going on where no events
    /// reach the app (`ElsewhereTurn`), unless it settled at the last row (`settledAt`, the chat's
    /// `KeptTurn.stoppedAt`) or the roster lost track of it there.
    public func shown(_ name: String, rows: [SessionMessage], settledAt: Int?, now: Date = .now) -> ElsewhereTurn? {
        guard !isLost(name, rows: rows) else { return nil }
        return ElsewhereTurn.of(rows, now: now, settledAt: settledAt)
    }

    /// The roster looks at the turn itself (`TurnRecovery`): the person's own turn stopping mid-work,
    /// which the gateway runs and can say whether it still does, not settled where it stops. One it
    /// lost track of is still looked at.
    public static func needsLook(_ rows: [SessionMessage], settledAt: Int?, now: Date = .now) -> Bool {
        TranscriptBuilder.endsOwnMidTurn(rows, now: now) && settledAt != TranscriptBuilder.lastTurnRowID(rows)
    }
}
