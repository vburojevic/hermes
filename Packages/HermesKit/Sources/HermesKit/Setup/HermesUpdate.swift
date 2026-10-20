import Foundation

// Updating Hermes Agent from the app (`docs/setup.md` §4.2): `POST /api/hermes/update` starts
// `hermes update` on the gateway and `GET /api/actions/hermes-update/status` follows it, the way
// the dashboard does (`web/src/contexts/SystemActions.tsx`, `hermes_cli/web_routers/actions.py`).

/// What `POST /api/hermes/update` answered.
public enum HermesUpdateStart: Sendable, Equatable {
    /// Running, or already running: the id names this run's receipt.
    case started(actionID: String?)
    /// Hermes won't update itself from here (a container, Nix, a managed install): its words,
    /// and the command to use instead when there is one.
    case refused(message: String, command: String?)

    public init(json: JSONValue) {
        if json["ok"]?.boolValue == false {
            // Hermes words these for its CLI: "✗ This Hermes runs from…", indented commands and
            // links, often with the command itself.
            let message = (json["message"]?.stringValue ?? "")
                .replacingOccurrences(of: "✗ ", with: "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let command = json["update_command"]?.stringValue.flatMap { $0.isEmpty || message.contains($0) ? nil : $0 }
            self = .refused(
                message: message.isEmpty ? String(localized: "Hermes doesn't update itself on this gateway.") : message,
                command: command
            )
        } else {
            self = .started(actionID: json["action_id"]?.stringValue)
        }
    }
}

/// `GET /api/actions/hermes-update/status`: whether the update still runs, how it exited, and
/// the receipt every `hermes update` writes.
public struct HermesUpdateStatus: Sendable, Equatable {
    public struct Receipt: Sendable, Equatable {
        /// `success`, `partial`, `failed`, `refused`…
        public var outcome: String?
        public var actionID: String?
        public var version: String?
        /// Steps a rerun of `hermes update` finishes, as Hermes names them.
        public var followups: [String]
        /// What only the person can do, in Hermes's words.
        public var userAction: String?
    }

    public var running: Bool
    public var exitCode: Int?
    /// The log's last line worth showing, while it runs and when it stops.
    public var lastLine: String?
    /// The log's tail as the route sent it, for `ActionLog.merge`.
    public var lines: [String]
    public var receipt: Receipt?

    public init(json: JSONValue) {
        running = json["running"]?.boolValue ?? false
        exitCode = json["exit_code"]?.truncatedIntValue
        lines = json["lines"].items.compactMap(\.stringValue)
        lastLine = lines.reversed().lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("===") }
        if case .object? = json["receipt"], let receipt = json["receipt"] {
            let step = { (row: JSONValue) -> String? in
                guard let name = row["step"]?.stringValue, !name.isEmpty else { return nil }
                let reason = row["reason"]?.stringValue ?? ""
                return reason.isEmpty ? name : "\(name) (\(reason))"
            }
            let actionReason = receipt["user_action"]?["reason"]?.stringValue ?? ""
            self.receipt = Receipt(
                outcome: receipt["outcome"]?.stringValue,
                actionID: receipt["action_id"]?.stringValue,
                version: receipt["post_version"]?.stringValue,
                followups: receipt["followups"].items.compactMap(step),
                userAction: receipt["user_action"]?["step"]?.stringValue.map { actionReason.isEmpty ? $0 : "\($0): \(actionReason)" }
            )
        }
    }

    /// What the run started as `actionID` came to; nil while it runs. Only a receipt carrying
    /// that id counts: the route attaches the latest one, which may be another profile's run
    /// (`updateDebt` in Hermes's `apps/shared/src/update-debt.ts`).
    public func outcome(actionID: String?) -> HermesUpdateOutcome? {
        guard !running else { return nil }
        let own = receipt.flatMap { receipt in actionID != nil && receipt.actionID == actionID ? receipt : nil }
        if let own, own.outcome == "success" || own.outcome == "partial" {
            let followups = own.followups.joined(separator: "; ")
            if !followups.isEmpty || own.userAction != nil {
                return .owes(followups: followups, userAction: own.userAction)
            }
        }
        switch exitCode {
        case 0?: return .updated(version: own?.version)
        case nil: return .unknown
        case let code?: return .failed(exitCode: code, lastLine: lastLine)
        }
    }
}

public enum HermesUpdateOutcome: Sendable, Equatable {
    case updated(version: String?)
    /// Updated, but Hermes still owes steps: ones another `hermes update` finishes, or the
    /// person's own (a rerun doesn't do those).
    case owes(followups: String, userAction: String?)
    case failed(exitCode: Int, lastLine: String?)
    /// Stopped without saying how: the dashboard restarted and kept no record yet.
    case unknown
}

/// An update the person started from the app, as the Hermes row shows it.
public enum HermesUpdateRun: Sendable, Equatable {
    case starting
    /// Its lines and step are in the `ActionLog` that follows it.
    case running
    case finished(HermesUpdateOutcome)
    case refused(message: String, command: String?)
    /// Lost touch with the gateway for too long while it updated.
    case lostTouch
    /// The start itself failed: the request's error, in words.
    case couldNotStart(message: String)
}

extension BackendClient {
    /// Whether Hermes Agent has an update (`GET /api/hermes/update/check`). Hermes caches the
    /// answer for a day, keyed by the checkout's commit, so it's fresh again after an update; the
    /// app never forces one.
    public func hermesUpdateCheck() async throws -> GatewaySetupFacts.UpdateCheck {
        GatewaySetupFacts.UpdateCheck(json: try await rest("api/hermes/update/check"))
    }

    /// Starts `hermes update` on the gateway. Only on the person's tap.
    public func startHermesUpdate() async throws -> HermesUpdateStart {
        HermesUpdateStart(json: try await rest("api/hermes/update", method: "POST"))
    }

    /// The update's status with enough of its log for `ActionLog` to follow it between polls.
    public func hermesUpdateStatus() async throws -> HermesUpdateStatus {
        HermesUpdateStatus(json: try await rest("api/actions/hermes-update/status", query: [URLQueryItem(name: "lines", value: "300")]))
    }
}
