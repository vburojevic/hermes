import Foundation

/// A widget the app can draw: its envelope, its primitive's fields, and the JSON they came from
/// (`docs/widgets.md` §3). Built only from payloads that passed `WidgetReader`.
public struct WidgetPayload: Decodable, Hashable, Sendable, Identifiable {
    public var envelope: WidgetEnvelope
    public var content: WidgetContent
    /// The payload as read: unknown fields left out, the fail-closed defaults applied.
    public var json: JSONValue

    public var id: String { envelope.id }
    public var rev: Int { envelope.rev }
    public var type: WidgetType { content.type }
    public var isPrivate: Bool { envelope.sensitivity == .private }

    public init(from decoder: any Decoder) throws {
        envelope = try WidgetEnvelope(from: decoder)
        guard let type = WidgetType(rawValue: envelope.type) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unknown widget type \(envelope.type)"))
        }
        content = try WidgetContent.decode(type, from: decoder)
        json = try JSONValue(from: decoder)
    }

    /// Decodes JSON that already passed validation.
    static func decode(_ json: JSONValue) throws -> WidgetPayload {
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(WidgetPayload.self, from: data)
    }

    /// The widgets a stack holds, in order; empty for every other type.
    public var children: [WidgetPayload] {
        if case .stack(let stack) = content { stack.children.compactMap(\.payload) } else { [] }
    }

    public var title: String { envelope.title }

    /// What VoiceOver, previews and notifications say: the summary, else the title.
    public var spokenSummary: String { envelope.summary ?? envelope.title }
}
