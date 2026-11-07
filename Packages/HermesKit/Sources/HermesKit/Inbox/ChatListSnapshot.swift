import Foundation

/// The chat list a device keeps between launches, one file per gateway
/// (`docs/connecting-and-voice.md` §8): the newest page of `GET /api/sessions` rows as they came.
/// A launch reads it before the first frame (about a millisecond for 200 rows), so the sidebar
/// opens on its chats rather than filling them in, animated, a moment later.
public enum ChatListSnapshot {
    /// The rows kept: the newest page, as far as a sidebar shows before scrolling for more.
    public static let maxRows = 200

    /// The rows a list lays out with the window's first frame: a tall Mac sidebar's screenful,
    /// with room to spare. Laying out all 200 with the window held it back about half a second,
    /// 40 hold it back about 0.14 s; the rest join the list right after it shows.
    public static let firstFrameRows = 40

    /// The rows to list: all of them, or before the first frame only the first `firstFrameRows`.
    public static func listed<Row>(_ rows: [Row], firstFrame: Bool) -> ArraySlice<Row> {
        firstFrame ? rows.prefix(firstFrameRows) : rows[...]
    }

    /// The file's contents for these chats, newest first as given, cut to `maxRows`; nil for none.
    public static func encode(_ sessions: [HermesSession]) -> Data? {
        guard !sessions.isEmpty else { return nil }
        return try? JSONEncoder().encode(Array(sessions.prefix(maxRows)))
    }

    /// The chats kept in the file at `url`; nil when there's no file or it can't be read, so a
    /// launch falls back to waiting for the gateway.
    public static func read(_ url: URL) -> [HermesSession]? {
        guard let data = try? Data(contentsOf: url),
              let sessions = try? JSONDecoder().decode([HermesSession].self, from: data),
              !sessions.isEmpty else { return nil }
        return sessions
    }
}
