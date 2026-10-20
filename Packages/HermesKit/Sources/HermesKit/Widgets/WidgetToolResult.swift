import Foundation

/// What the `widget` tool returns (`docs/widgets.md` §2): `{id, rev, directive, fallback_text,
/// children, payload}` for `create`, `update`, `resolve` and `get`; a claim's verdict for `claim`.
/// The app reads it live from `tool.complete.result` (the backend socket) and from the stored
/// tool row when a chat opens or a run's `tool.completed` names the tool (the run stream carries
/// only a short preview).
public enum WidgetToolResult {
    /// Tools whose steps the transcript hides: the card is the step.
    public static let toolNames: Set<String> = ["widget", "widget_examples"]
    public static let widgetTool = "widget"

    /// The payload a result carries, or `nil` for errors, claims and anything else.
    public static func payload(from result: JSONValue) -> JSONValue? {
        let object: JSONValue
        if let text = result.stringValue {
            guard let parsed = JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            object = parsed
        } else {
            object = result
        }
        guard case .object(let payload)? = object["payload"], payload["id"]?.stringValue != nil,
              payload["type"]?.stringValue != nil else { return nil }
        return .object(payload)
    }

    public static func payload(fromText text: String) -> JSONValue? {
        payload(from: .string(text))
    }
}
