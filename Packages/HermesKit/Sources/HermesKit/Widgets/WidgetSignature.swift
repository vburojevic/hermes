import Foundation

/// Signed answers (`docs/widgets.md` §6, contract §6.3): the answers that need Face ID or Touch ID
/// first and, once this device has registered its key, the device's signature over
/// `WidgetAnswer.signingInput`. The rule is the plugin's own (`fallback.requires_signature` and
/// `needs_signature`), so the app asks exactly when the plugin will check.
public enum WidgetSignature {
    /// Approving an approval that costs money, can't be undone, needs authentication or is a
    /// transfer, and any action marked `requires: authentication`.
    public static func isRequired(_ payload: JSONValue, action: String) -> Bool {
        if action == "approve", approvalNeedsSignature(payload) { return true }
        return hasAuthenticatedAction(action, in: payload)
    }

    static func approvalNeedsSignature(_ payload: JSONValue) -> Bool {
        guard payload["type"]?.stringValue == "approval" else { return false }
        let subject = payload["subject"]
        let consequences = payload["consequences"]
        let known: Set<String> = ["purchase", "message", "post", "release", "spend", "delete", "booking", "transfer", "other"]
        guard let kind = subject?["kind"]?.stringValue, known.contains(kind), !["transfer", "purchase", "spend"].contains(kind) else {
            return true
        }
        if payload["authentication"]?.stringValue == "required" { return true }
        if !["yes", "until"].contains(consequences?["reversible"]?.stringValue ?? "") { return true }
        let amounts = [consequences?["cost"]?["amount"]?["value"], subject?["amount"]?["value"]]
        return amounts.contains { value in
            if case .number(let number)? = value { number != 0 } else { false }
        }
    }

    private static func hasAuthenticatedAction(_ action: String, in value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            if object["id"]?.stringValue == action, object["requires"]?.stringValue == "authentication" { return true }
            return object.values.contains { hasAuthenticatedAction(action, in: $0) }
        case .array(let array):
            return array.contains { hasAuthenticatedAction(action, in: $0) }
        default:
            return false
        }
    }
}
