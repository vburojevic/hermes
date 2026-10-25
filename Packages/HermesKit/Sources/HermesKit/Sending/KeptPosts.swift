import Foundation

/// A group chat's message on its way to the room, kept on the device until Hermes takes it, so a
/// relaunch while the Mac is away loses nothing (`docs/bots-groups-skills.md` §2). It goes again
/// under the same `event_id`: Hermes appends a person's message to a room once per id
/// (`groups.send`), so sending it again can't put it in the room twice.
public struct KeptPost: Codable, Sendable, Equatable {
    public let eventID: String
    public let text: String

    public init(eventID: String, text: String) {
        self.eventID = eventID
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case text
    }

    public static func encode(_ posts: [KeptPost]) -> Data? {
        try? JSONEncoder().encode(posts)
    }

    public static func decode(_ data: Data) -> [KeptPost] {
        (try? JSONDecoder().decode([KeptPost].self, from: data)) ?? []
    }
}
