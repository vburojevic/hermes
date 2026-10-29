import Foundation

/// Hermes moving a chat between models: onto a fallback when the primary fails, and back to the
/// primary as the next turn starts (`docs/chat.md` §2, "Model switches").
///
/// Read from Hermes's own lines (hermes-agent v0.22.5): the fallback from
/// `agent/chat_completion_helpers.py` `try_activate_fallback`, sent as the turn ends
/// (`agent/turn_final_response.py` `_emit_pending_fallback_notice`); the "↻" form from
/// `agent/turn_empty_response.py`; the restore from `agent/agent_runtime_helpers.py`
/// `restore_primary_runtime`, sent before the primary has answered anything.
public enum ModelSwitch: Sendable, Equatable {
    case fallback(Route)
    /// Hermes went back to the primary. It says nothing about whether the primary works: one that
    /// keeps failing is restored and falls back again on every turn.
    case restored(primary: Model, fallback: Model?)

    /// A model as Hermes names it: "claude-opus-5-5 via anthropic".
    public struct Model: Sendable, Equatable {
        public var name: String
        public var provider: String

        public init(name: String, provider: String) {
            self.name = name
            self.provider = provider
        }
    }

    public struct Route: Sendable, Equatable {
        /// The model that failed; the "↻" form doesn't name it.
        public var primary: Model?
        public var fallback: Model
        /// Why, in Hermes's words ("provider server error", "rate limit").
        public var reason: String?

        public init(primary: Model?, fallback: Model, reason: String?) {
            self.primary = primary
            self.fallback = fallback
            self.reason = reason
        }

        /// The turn's note, in Hermes's words. Without its "Primary retry eligible in ~N s", which
        /// is out of date as soon as the note stays on the turn.
        public var note: String {
            guard let primary else { return "Switched to fallback: \(fallback.name) (\(fallback.provider))" }
            let reason = reason.map { " (\($0))" } ?? ""
            return "Model fallback: \(primary.name) via \(primary.provider) unavailable\(reason); using \(fallback.name) via \(fallback.provider)."
        }

        /// The same switch: the same fallback, from the same primary when both name it.
        func isSame(as other: Route) -> Bool {
            fallback == other.fallback && (primary == nil || other.primary == nil || primary == other.primary)
        }
    }

    public init?(line: String) {
        let body = String(String.UnicodeScalarView(line.unicodeScalars.drop {
            $0 == "\u{26A0}" || $0 == "\u{21BB}" || $0 == "\u{2705}" || $0 == "\u{FE0F}" || $0.properties.isWhitespace
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = body.firstMatch(of: #/^Model fallback: (.+?) via (\S+) unavailable \((.*)\); using (.+?) via (\S+?)\.(?:\s|$)/#) {
            self = .fallback(Route(primary: Model(name: String(match.1), provider: String(match.2)),
                                   fallback: Model(name: String(match.4), provider: String(match.5)),
                                   reason: String(match.3).isEmpty ? nil : String(match.3)))
        } else if let match = body.firstMatch(of: #/^Switched to fallback: (.+) \(([^()]*)\)$/#) {
            self = .fallback(Route(primary: nil, fallback: Model(name: String(match.1), provider: String(match.2)), reason: nil))
        } else if let match = body.firstMatch(of: #/^Primary model restored: (.+?) via (\S+?)(?:; fallback (.+?) via (\S+) is no longer active\.?)?$/#) {
            self = .restored(primary: Model(name: String(match.1), provider: String(match.2)),
                             fallback: match.3.flatMap { name in match.4.map { Model(name: String(name), provider: String($0)) } })
        } else {
            return nil
        }
    }
}

/// A chat's model switches as the person should see them: a fallback once per actual switch, a
/// restore never (`docs/chat.md` §2). Hermes says both on every turn while a primary keeps failing,
/// so one chat keeps one of these across its turns and passes its events through it.
public struct ModelSwitchNotes: Sendable, Equatable {
    /// The fallback the chat has shown a note for, while it keeps falling back to it.
    public private(set) var shown: ModelSwitch.Route?
    private var restoredThisTurn = false
    private var fellBackThisTurn = false

    public init() {}

    public mutating func filter(_ events: [SequencedTurnEvent]) -> [SequencedTurnEvent] {
        events.filter { keep($0.event) }
    }

    /// Whether the event goes on to the turn. A fallback the chat already shows doesn't; a turn
    /// that ends on the primary (restored at its start, no fallback by its end) ends that, so a
    /// later fallback shows again.
    public mutating func keep(_ event: TurnEvent) -> Bool {
        switch event {
        case .modelSwitch(.restored):
            restoredThisTurn = true
            return false
        case .modelSwitch(.fallback(let route)):
            fellBackThisTurn = true
            if let shown, shown.isSame(as: route) {
                if shown.primary == nil { self.shown = route }
                return false
            }
            shown = route
        case .completed:
            if restoredThisTurn && !fellBackThisTurn { shown = nil }
            endTurn()
        case .failed, .held, .cancelled, .interrupted, .settled:
            endTurn()
        default:
            break
        }
        return true
    }

    private mutating func endTurn() {
        restoredThisTurn = false
        fellBackThisTurn = false
    }
}
