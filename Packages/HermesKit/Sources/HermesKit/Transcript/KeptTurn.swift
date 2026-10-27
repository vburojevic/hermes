import Foundation

/// What the device keeps of a chat's last turn across launches (`docs/chat.md` §2): never its words,
/// only what says how it stands. Kept in memory alone, a turn settled as "Stopped" showed as working
/// again after the next relaunch until the gateway was asked again, about 30 s, and a run the app
/// started over the API server was forgotten with the app, so its end could only be guessed from
/// the stored rows' age (20 minutes).
public struct KeptTurn: Codable, Sendable, Equatable {
    /// The run this device started over the API server and hasn't heard end (`UnheardRun`).
    public var runID: String?
    /// The stored row a turn that died mid-work ended at: it shows as stopped there
    /// (`TranscriptBuilder.settleMidTurn`) until a row is stored after it.
    public var stoppedAt: Int?

    public init(runID: String? = nil, stoppedAt: Int? = nil) {
        self.runID = runID
        self.stoppedAt = stoppedAt
    }

    public var isEmpty: Bool { runID == nil && stoppedAt == nil }

    /// The mark as it stands with these stored rows: gone once a row is stored after it (the turn
    /// went on after all, or a later turn came), so it never settles a turn it wasn't set for. Rows
    /// that don't reach it yet (an older copy kept on the device) keep it.
    public func stillStopped(in messages: [SessionMessage]) -> KeptTurn {
        guard let stoppedAt, let last = TranscriptBuilder.lastTurnRowID(messages), last > stoppedAt else { return self }
        return KeptTurn(runID: runID, stoppedAt: nil)
    }
}

extension TranscriptBuilder {
    /// A turn that ended without finishing (stopped, interrupted, failed) while its stored rows stop
    /// partway: they end there, so its mark is their last row (`KeptTurn.stoppedAt`). Without it a
    /// relaunch drew those rows as a turn still working (`markMidTurn`), for 20 minutes over the API
    /// server. `nil` for a turn that finished, or whose stored rows hold it whole.
    public static func stoppedMark(endedAs state: AssistantTurn.State, messages: [SessionMessage], now: Date = .now) -> Int? {
        switch state {
        case .stopped, .failed: break
        case .complete, .streaming, .waitingForApproval: return nil
        }
        guard endsOwnMidTurn(messages, now: now) else { return nil }
        return lastTurnRowID(messages)
    }

    /// A stored turn that stops mid-work, whose run couldn't be asked how it stands for the whole of
    /// the recovery's minute (`UnheardRun`): it says so, and why, with Reload (`AssistantTurn.lost`),
    /// rather than showing as working until its rows are 20 minutes old. Known by its last stored
    /// row, as `settleMidTurn`'s mark is: a row stored after it ends it. Returns whether it did.
    @discardableResult
    public static func loseMidTurn(_ items: inout [TranscriptItem], messages: [SessionMessage], at mark: (row: Int, reason: LostTurn)?) -> Bool {
        guard let mark, let last = lastTurnRow(messages), last.id == mark.row,
              let index = items.indices.last, case .assistant(let turn) = items[index] else { return false }
        items[index] = .assistant(turn.lost(mark.reason, now: last.timestamp ?? .now))
        return true
    }
}

/// Each chat's `KeptTurn` on this device, by the chat's key.
public final class KeptTurns {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ chat: String) -> String { "turn.\(chat)" }

    public func turn(for chat: String) -> KeptTurn {
        defaults.data(forKey: Self.key(chat)).flatMap { try? JSONDecoder().decode(KeptTurn.self, from: $0) } ?? KeptTurn()
    }

    public func set(_ turn: KeptTurn, for chat: String) {
        defaults.set(turn.isEmpty ? nil : try? JSONEncoder().encode(turn), forKey: Self.key(chat))
    }

    /// A removed gateway's: every chat's, its Bot Chats' too (their keys start with the gateway's id).
    public func removeAll(gateway: UUID) {
        let prefixes = [Self.key("\(gateway.uuidString)-"), Self.key("bot-\(gateway.uuidString)-")]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// A run this device started over the API server whose end it never heard: the app was quit or
/// relaunched while it ran (`docs/chat.md` §2, over the API server). Hermes keeps the status of a
/// run started with an `Idempotency-Key`, which the app always sends, for a day and over a restart:
/// one a restart cut off reads `interrupted` ("The gateway restarted before this run settled.";
/// hermes-agent `gateway/platforms/api_server_runs.py` `_durable_run_status`). Its status says what
/// the stored rows can't: whether anything still runs for the chat.
public enum UnheardRun {
    /// What the app does next.
    public enum Step: Sendable, Equatable {
        /// It still runs (or waits its turn, or waits on the person): it carries on live in its
        /// place, followed by its status, and the stored reply shows when it ends (`RunFollow`).
        case follow
        /// It ended without finishing (interrupted, stopped, failed): stored rows that stop partway
        /// end there, "Stopped", at once.
        case settle
        /// It finished, and its reply may be stored a moment late; or Hermes no longer has it, so
        /// nothing runs for it: the stored chat says how it ended, read on `TurnRecovery`'s backoff.
        case readStored
        /// Hermes couldn't be asked: ask again.
        case askAgain
    }

    /// - Parameters:
    ///   - status: the run's status (`GET /v1/runs/{id}`).
    ///   - sessionID: the chat's. A status that names another chat isn't this chat's turn.
    public static func next(status: Result<RunStatus, any Error>, sessionID: String?) -> Step {
        switch status {
        case .success(let run):
            if let owner = run.sessionID, let sessionID, owner != sessionID { return .readStored }
            guard run.isTerminal else { return .follow }
            return run.status == "completed" ? .readStored : .settle
        case .failure(let error):
            if case .notFound? = error as? HermesError { return .readStored }
            return .askAgain
        }
    }
}
